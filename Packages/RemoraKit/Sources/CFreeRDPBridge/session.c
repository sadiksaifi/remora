#include "CFreeRDPBridge.h"
#include "input.h"
#include "clipboard.h"
#include "display.h"
#include "reconnect.h"

#define WITH_OPAQUE_SETTINGS
/* WinPR's own public sspi.h declares fields with deprecated WinPR types. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/error.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/utils/gfx.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/transport_io.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#pragma clang diagnostic pop

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Darwin modules and WinPR both export these macros. Choose C boolean values. */
#undef TRUE
#undef FALSE
#define TRUE true
#define FALSE false

struct RMRDPSession {
    rdpClientContext client; /* Must remain first: client-common requires this prefix. */
    RMRDPCallbacks callbacks;
    void *user;
    atomic_bool aborted;
    RMInput *input;
    RMClipboard *clipboard;
    RMDisplay *display;
    pcRdpgfxSurfaceCommand surface_command;
    UINT32 last_codec;
    bool reconnecting;
    bool credentials_cancelled;
    bool certificate_rejected;
    unsigned credential_requests;
    RMRDPDisconnectReason network_error;
    int socket_error;
};

RMInput *rm_rdp_input(RMRDPSession *s) { return s->input; }
RMClipboard *rm_rdp_clipboard(RMRDPSession *s) { return s->clipboard; }
RMDisplay *rm_rdp_display(RMRDPSession *s) { return s->display; }

static rdpContext *context_of(RMRDPSession *s) { return &s->client.context; }
static RMRDPSession *session_of(rdpContext *context) { return (RMRDPSession *)context; }

static os_log_t engine_log;

static BOOL log_message(const wLogMessage *message) {
    os_log_with_type(engine_log, message->Level >= WLOG_ERROR ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT,
                     "%{public}s: %{public}s", message->FunctionName ? message->FunctionName : "FreeRDP",
                     message->TextString ? message->TextString : "");
    return TRUE;
}

static void configure_logging(void) {
    engine_log = os_log_create("dev.sadiksaifi.Remora", "FreeRDP");
    wLog *root = WLog_GetRoot();
    (void)WLog_SetLogLevel(root, WLOG_WARN);
    /* The backend reports the selected hw device and any software fallback. */
    (void)WLog_SetLogLevel(WLog_Get("com.freerdp.codec"), WLOG_INFO);
    if (WLog_SetLogAppenderType(root, WLOG_APPENDER_CALLBACK)) {
        wLogCallbacks callbacks = { .message = log_message };
        (void)WLog_ConfigureAppender(WLog_GetLogAppender(root), "callbacks", &callbacks);
        (void)WLog_OpenAppender(root);
    }
}

static uint64_t milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

/* FreeRDP 3.32.2 discards SO_ERROR and reports CONNECT_FAILED for both refusal
 * and timeout (core/tcp.c). Its public TCPConnect hook is the narrow place to
 * retain that distinction. FreeRDP still owns the connected socket and all
 * transport, TLS, NLA, RDSTLS and redirection behavior. */
static int tcp_connect(rdpContext *context, rdpSettings *settings, const char *host,
                       int port, DWORD timeout) {
    RMRDPSession *s = session_of(context);
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM };
    struct addrinfo *addresses = NULL;
    char service[16];
    snprintf(service, sizeof(service), "%d", port);
    s->network_error = RMRDP_DISCONNECT_NONE;
    s->socket_error = 0;
    if (getaddrinfo(host, service, &hints, &addresses) != 0) {
        s->network_error = RMRDP_DISCONNECT_HOST_NOT_FOUND;
        freerdp_set_last_error(context, FREERDP_ERROR_DNS_NAME_NOT_FOUND);
        return -1;
    }

    const uint64_t deadline = milliseconds() + ((timeout && timeout < 12000) ? timeout : 12000);
    int result = -1;
    int error = ETIMEDOUT;
    for (const struct addrinfo *a = addresses; a && milliseconds() < deadline; a = a->ai_next) {
        if (atomic_load(&s->aborted))
            break;
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) {
            error = errno;
            continue;
        }
        const int flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            error = errno;
            close(fd);
            continue;
        }
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        error = rc == 0 ? 0 : errno;
        if (error == EINPROGRESS) {
            error = ETIMEDOUT;
            while (!atomic_load(&s->aborted) && milliseconds() < deadline) {
                struct pollfd pfd = { .fd = fd, .events = POLLOUT };
                rc = poll(&pfd, 1, 50);
                if (rc < 0 && errno == EINTR)
                    continue;
                if (rc < 0) {
                    error = errno;
                    break;
                }
                if (rc > 0) {
                    socklen_t length = sizeof(error);
                    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0)
                        error = errno;
                    break;
                }
            }
        }
        if (error == 0 && !atomic_load(&s->aborted)) {
            if (fcntl(fd, F_SETFL, flags) == 0) {
                result = fd;
                break;
            }
            error = errno;
        }
        close(fd);
    }
    freeaddrinfo(addresses);
    if (result >= 0) {
        /* Preserve the default connector's client-address announcement and low
         * latency. The core's TCP layer configures keepalive and SO_NOSIGPIPE. */
        const int enabled = 1;
        (void)setsockopt(result, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
        /* FreeRDP configures TCP_KEEPIDLE, which macOS does not expose. Use
         * its TCP_KEEPALIVE equivalent so an idle lost path reaches recovery. */
        const int idle = (int)freerdp_settings_get_uint32(settings, FreeRDP_TcpKeepAliveDelay);
        if (freerdp_settings_get_bool(settings, FreeRDP_TcpKeepAlive))
            (void)setsockopt(result, IPPROTO_TCP, TCP_KEEPALIVE, &idle, sizeof(idle));
        struct sockaddr_storage local = { 0 };
        socklen_t length = sizeof(local);
        char address[NI_MAXHOST];
        if (getsockname(result, (struct sockaddr *)&local, &length) != 0 ||
            getnameinfo((struct sockaddr *)&local, length, address, sizeof(address),
                        NULL, 0, NI_NUMERICHOST) != 0 ||
            !freerdp_settings_set_string(settings, FreeRDP_ClientAddress, address) ||
            !freerdp_settings_set_bool(settings, FreeRDP_IPv6Enabled, local.ss_family == AF_INET6)) {
            close(result);
            result = -1;
            error = EIO;
        }
    }
    if (result < 0) {
        s->socket_error = error;
        switch (error) {
            case ECONNREFUSED:
                s->network_error = RMRDP_DISCONNECT_CONNECTION_REFUSED;
                break;
            case ETIMEDOUT:
            case ENETUNREACH:
            case EHOSTUNREACH:
            case ENETDOWN:
            case EHOSTDOWN:
                s->network_error = RMRDP_DISCONNECT_CONNECTION_TIMED_OUT;
                break;
            default:
                s->network_error = RMRDP_DISCONNECT_PROTOCOL_ERROR;
                break;
        }
        freerdp_set_last_error_if_not(context, atomic_load(&s->aborted)
            ? FREERDP_ERROR_CONNECT_CANCELLED : FREERDP_ERROR_CONNECT_FAILED);
    }
    return result;
}

static BOOL request_credentials(RMRDPSession *s, char **username, char **password,
                                 char **domain, bool rejected) {
    if (atomic_load(&s->aborted) || s->credentials_cancelled || s->credential_requests >= 4)
        return FALSE;
    s->credential_requests++;
    char *u = NULL, *d = NULL, *p = NULL;
    const bool accepted = s->callbacks.credentials && s->callbacks.credentials(
        s->user, *username ? *username : "", *domain ? *domain : "", rejected, &u, &d, &p);
    if (!accepted || !u || !d || !p || atomic_load(&s->aborted)) {
        free(u);
        free(d);
        free(p);
        s->credentials_cancelled = !accepted;
        return FALSE;
    }
    free(*username);
    free(*domain);
    free(*password);
    *username = u;
    *domain = d;
    *password = p;
    return TRUE;
}

static BOOL authenticate(freerdp *instance, char **username, char **password,
                         char **domain, rdp_auth_reason reason) {
    (void)reason;
    RMRDPSession *s = session_of(instance->context);
    if (s->reconnecting)
        return FALSE; /* Recovery uses persisted RDP credentials without prompting. */
    if (!request_credentials(s, username, password, domain,
                              *username && (*username)[0] && *password))
        return FALSE;
    /* The core's backup settings must see credentials supplied after PreConnect,
     * including for GNOME Remote Login's transparent RDSTLS handover. */
    return freerdp_persist_credentials(instance->context);
}

static DWORD verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                const char *common_name, const char *subject,
                                const char *issuer, const char *fingerprint, DWORD flags) {
    (void)common_name;
    (void)flags;
    RMRDPSession *s = session_of(instance->context);
    const bool trust = !atomic_load(&s->aborted) && s->callbacks.trust &&
        s->callbacks.trust(s->user, host, port, subject, issuer, fingerprint, NULL);
    s->certificate_rejected = !trust;
    return trust ? 1 : 0; /* FreeRDP accepts and persists when returning 1. */
}

static DWORD verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                        const char *common_name, const char *subject,
                                        const char *issuer, const char *fingerprint,
                                        const char *old_subject, const char *old_issuer,
                                        const char *old_fingerprint, DWORD flags) {
    (void)common_name;
    (void)old_subject;
    (void)old_issuer;
    (void)flags;
    RMRDPSession *s = session_of(instance->context);
    const bool trust = !atomic_load(&s->aborted) && s->callbacks.trust &&
        s->callbacks.trust(s->user, host, port, subject, issuer, fingerprint, old_fingerprint);
    s->certificate_rejected = !trust;
    return trust ? 1 : 0;
}

static BOOL begin_paint(rdpContext *context) {
    HGDI_WND window = context->gdi->primary->hdc->hwnd;
    window->invalid->null = TRUE;
    window->ninvalid = 0;
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    RMRDPSession *s = session_of(context);
    rdpGdi *gdi = context->gdi;
    HGDI_WND window = gdi->primary->hdc->hwnd;
    if (!window->invalid->null && window->ninvalid > 0 && s->callbacks.frame) {
        const size_t count = (size_t)window->ninvalid;
        RMRDPRectangle *rectangles = calloc(count, sizeof(*rectangles));
        if (!rectangles)
            return FALSE;
        for (size_t i = 0; i < count; i++) {
            const GDI_RGN *r = &window->cinvalid[i];
            rectangles[i] = (RMRDPRectangle){ r->x, r->y, r->w, r->h };
        }
        s->callbacks.frame(s->user, gdi->primary_buffer, gdi->width, gdi->height,
                           gdi->stride, rectangles, count);
        free(rectangles);
    }
    window->invalid->null = TRUE;
    window->ninvalid = 0;
    return TRUE;
}

static void report_size(RMRDPSession *s) {
    rdpGdi *gdi = context_of(s)->gdi;
    const bool requested = rm_display_resized(s->display, gdi->width, gdi->height);
    if (s->callbacks.desktop_size)
        s->callbacks.desktop_size(s->user, gdi->width, gdi->height, requested);
}

static BOOL desktop_resize(rdpContext *context) {
    if (!gdi_resize(context->gdi,
                    freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
                    freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight)))
        return FALSE;
    report_size(session_of(context));
    return TRUE;
}

static BOOL pre_connect(freerdp *instance) {
    if (!atomic_load(&session_of(instance->context)->aborted))
        return TRUE;
    (void)freerdp_abort_connect_context(instance->context);
    return FALSE;
}

static BOOL post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;
    instance->context->update->BeginPaint = begin_paint;
    instance->context->update->EndPaint = end_paint;
    instance->context->update->DesktopResize = desktop_resize;
    rm_input_register_pointer(session_of(instance->context)->input);
    report_size(session_of(instance->context));
    return TRUE;
}

static void post_disconnect(freerdp *instance) {
    gdi_free(instance); /* Also safe when PostConnect was never reached. */
}

/* Observe the actual wire codec after client-common installs GDI. Keep its
 * context and decoder callbacks intact; GDI still owns all rendering. */
static UINT surface_command(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_COMMAND *command) {
    rdpGdi *gdi = gfx->custom;
    RMRDPSession *s = session_of(gdi->context);
    const UINT status = s->surface_command(gfx, command);
    if (status == CHANNEL_RC_OK && s->last_codec != command->codecId) {
        s->last_codec = command->codecId;
        os_log_info(engine_log, "GFX codec: %{public}s (0x%04x)",
                    rdpgfx_get_codec_id_string(command->codecId), command->codecId);
    }
    return status;
}

static void graphics_connected(void *context, const ChannelConnectedEventArgs *event) {
    if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) != 0)
        return;
    RMRDPSession *s = session_of(context);
    RdpgfxClientContext *gfx = event->pInterface;
    s->surface_command = gfx->SurfaceCommand;
    s->last_codec = UINT32_MAX;
    gfx->SurfaceCommand = surface_command;
}

static BOOL client_new(freerdp *instance, rdpContext *context) {
    instance->AuthenticateEx = authenticate;
    instance->VerifyCertificateEx = verify_certificate;
    instance->VerifyChangedCertificateEx = verify_changed_certificate;
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    if (PubSub_SubscribeChannelConnected(context->pubSub,
            freerdp_client_OnChannelConnectedEventHandler) < 0 ||
        PubSub_SubscribeChannelDisconnected(context->pubSub,
            freerdp_client_OnChannelDisconnectedEventHandler) < 0 ||
        PubSub_SubscribeChannelConnected(context->pubSub, rm_clipboard_channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(context->pubSub, rm_clipboard_channel_disconnected) < 0 ||
        PubSub_SubscribeChannelConnected(context->pubSub, graphics_connected) < 0)
        return FALSE;
    rdpTransportIo io = *freerdp_get_io_callbacks(context);
    io.TCPConnect = tcp_connect;
    return freerdp_set_io_callbacks(context, &io);
}

RMRDPSession *rm_rdp_create(const RMRDPConfiguration *config, const RMRDPCallbacks *callbacks,
                           void *user) {
    if (!config || !callbacks || !config->host || !config->host[0] || !config->port ||
        !config->config_path || !config->width || !config->height ||
        config->width > 32766 || config->height > 32766 ||
        !isfinite(config->scale_factor) || config->scale_factor < 1 || config->scale_factor > 5)
        return NULL;
    static pthread_once_t logging_once = PTHREAD_ONCE_INIT;
    pthread_once(&logging_once, configure_logging);
    RDP_CLIENT_ENTRY_POINTS entry = { 0 };
    entry.Size = sizeof(entry);
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.ContextSize = sizeof(RMRDPSession);
    entry.ClientNew = client_new;
    rdpContext *context = freerdp_client_context_new(&entry);
    if (!context)
        return NULL;
    RMRDPSession *s = session_of(context);
    s->callbacks = *callbacks;
    s->user = user;
    atomic_init(&s->aborted, false);
    s->input = rm_input_new(context, callbacks, user, config->iso_keyboard);
    s->clipboard = rm_clipboard_new(callbacks, user);
    s->display = rm_display_new(context, callbacks, user);
    if (!s->input || !s->clipboard || !s->display) {
        rm_rdp_free(s);
        return NULL;
    }
    rdpSettings *settings = context->settings;
    const UINT32 scale = (UINT32)lround(config->scale_factor * 100);
    /* MS-RDPBCGR permits only 100, 140 or 180 for DeviceScaleFactor. */
    const UINT32 device_scale = scale >= 180 ? 180 : scale >= 140 ? 140 : 100;
    const BOOL ok =
        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, config->host) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, config->port) &&
        freerdp_settings_set_string(settings, FreeRDP_Username, config->username) &&
        freerdp_settings_set_string(settings, FreeRDP_Domain, config->domain) &&
        freerdp_settings_set_string(settings, FreeRDP_Password, config->password) &&
        freerdp_settings_set_string(settings, FreeRDP_ConfigPath, config->config_path) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, config->width) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, config->height) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, scale) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, device_scale) &&
        freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, config->keyboard_layout) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, 12000) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, TRUE) &&
        /* GDI still converts into our BGRA buffer. This flag lets its H.264
         * contexts request FFmpeg hardware acceleration with software fallback. */
        freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, FALSE) &&
        /* Allow transient Tailscale path loss: the defaults (5/2/3 seconds)
         * abandon an unacknowledged connection after about 11 seconds. */
        freerdp_settings_set_bool(settings, FreeRDP_TcpKeepAlive, TRUE) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveDelay, 30) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveInterval, 10) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveRetries, 6) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, config->dynamic_resolution) &&
        freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, config->dynamic_resolution) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, TRUE) &&
        freerdp_settings_set_uint32(settings, FreeRDP_AutoReconnectMaxRetries, 20) &&
        /* These require rdpdr, which forces an rdpsnd addin even with sound off.
         * This engine omits rdpsnd. None are needed for the session slice. */
        freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, TRUE);
    if (!ok) {
        rm_rdp_free(s);
        return NULL;
    }
    /* utils_reload_channels inside freerdp_connect calls client-common's
     * freerdp_client_load_addins, enabling drdynvc, rdpgfx and disp from settings. */
    return s;
}

static bool authentication_failed(UINT32 error) {
    switch (error) {
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_INSUFFICIENT_PRIVILEGES:
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
        case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED:
        case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_CLIENT_REVOKED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
            return true;
        default:
            return false;
    }
}

static BOOL retry_credentials(RMRDPSession *s) {
    rdpSettings *settings = context_of(s)->settings;
    const char *username = freerdp_settings_get_string(settings, FreeRDP_Username);
    const char *domain = freerdp_settings_get_string(settings, FreeRDP_Domain);
    char *u = strdup(username ? username : "");
    char *d = strdup(domain ? domain : "");
    char *p = NULL;
    BOOL ok = u && d && request_credentials(s, &u, &p, &d, true);
    if (ok)
        ok = freerdp_settings_set_string(settings, FreeRDP_Username, u) &&
             freerdp_settings_set_string(settings, FreeRDP_Domain, d) &&
             freerdp_settings_set_string(settings, FreeRDP_Password, p);
    free(u);
    free(d);
    free(p);
    return ok;
}

void rm_rdp_run(RMRDPSession *s) {
    rdpContext *context = context_of(s);
    freerdp *instance = context->instance;
    BOOL connected = FALSE;
    for (unsigned retry = 0; !atomic_load(&s->aborted); retry++) {
        connected = freerdp_connect(instance);
        if (connected || !authentication_failed(freerdp_get_last_error(context)) ||
            retry >= 3 || !retry_credentials(s))
            break;
    }
    bool loop_failed = false;
    if (connected) {
        if (s->callbacks.connected)
            s->callbacks.connected(s->user);
        while (!atomic_load(&s->aborted)) {
            const DWORD resize_timeout = rm_display_process(s->display);
            HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
            const DWORD count = freerdp_get_event_handles(context, handles, MAXIMUM_WAIT_OBJECTS - 3);
            handles[count] = rm_input_event(s->input);
            handles[count + 1] = rm_clipboard_event(s->clipboard);
            handles[count + 2] = rm_display_event(s->display);
            if (freerdp_shall_disconnect_context(context) || !count ||
                WaitForMultipleObjects(count + 3, handles, FALSE, resize_timeout) == WAIT_FAILED ||
                !freerdp_check_event_handles(context) || !rm_input_drain(s->input) ||
                !rm_clipboard_drain(s->clipboard)) {
                s->reconnecting = true;
                const BOOL recovered = rm_reconnect(instance, s->input, &s->callbacks, s->user, &s->aborted);
                s->reconnecting = false;
                if (recovered) {
                    rm_rdp_release_all(s);
                    rm_display_reconnected(s->display);
                    if (s->callbacks.connected)
                        s->callbacks.connected(s->user);
                    continue;
                }
                loop_failed = true;
                break;
            }
        }
    }
    const UINT32 error = freerdp_get_last_error(context);
    const UINT32 info = freerdp_error_info(instance);
    RMRDPDisconnectReason reason = RMRDP_DISCONNECT_NONE;
    const char *message = freerdp_get_last_error_string(error);
    char detail[512];
    if (s->socket_error) {
        snprintf(detail, sizeof(detail), "%s (%s)", message, strerror(s->socket_error));
        message = detail;
    }
    if (atomic_load(&s->aborted) || s->credentials_cancelled || error == FREERDP_ERROR_CONNECT_CANCELLED)
        reason = RMRDP_DISCONNECT_CANCELLED;
    else if (s->certificate_rejected)
        reason = RMRDP_DISCONNECT_CERTIFICATE_REJECTED;
    else if (authentication_failed(error))
        reason = RMRDP_DISCONNECT_AUTHENTICATION_FAILED;
    else if (error == FREERDP_ERROR_DNS_NAME_NOT_FOUND || error == FREERDP_ERROR_DNS_ERROR)
        reason = RMRDP_DISCONNECT_HOST_NOT_FOUND;
    else if (error == FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT ||
             error == FREERDP_ERROR_CONNECT_KDC_UNREACHABLE)
        reason = RMRDP_DISCONNECT_CONNECTION_TIMED_OUT;
    else if (s->network_error != RMRDP_DISCONNECT_NONE)
        reason = s->network_error;
    else if (info != ERRINFO_SUCCESS) {
        reason = RMRDP_DISCONNECT_SERVER_ENDED_SESSION;
        message = freerdp_get_error_info_string(info);
    } else if (error != FREERDP_ERROR_SUCCESS || !connected || loop_failed)
        reason = RMRDP_DISCONNECT_PROTOCOL_ERROR;
    if (connected)
        (void)freerdp_disconnect(instance);
    if (s->callbacks.disconnected)
        s->callbacks.disconnected(s->user, reason, message);
}

void rm_rdp_abort(RMRDPSession *s) {
    atomic_store(&s->aborted, true);
    (void)freerdp_abort_connect_context(context_of(s));
}

void rm_rdp_free(RMRDPSession *s) {
    if (s) {
        RMInput *input = s->input;
        RMClipboard *clipboard = s->clipboard;
        RMDisplay *display = s->display;
        freerdp_client_context_free(context_of(s));
        rm_input_free(input);
        rm_clipboard_free(clipboard);
        rm_display_free(display);
    }
}
