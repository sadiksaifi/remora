#include "CFreeRDPTestServer.h"

#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/privatekey.h>
#include <freerdp/freerdp.h>
#include <freerdp/peer.h>
#include <freerdp/settings.h>
#include <winpr/ssl.h>
#include <winpr/synch.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct RMTestRDPServer {
    int listener;
    uint16_t port;
    /* The pipe wakes the accept wait. The event wakes the connection loop. */
    int wake[2];
    HANDLE stop;
    /* A duplicate of the accepted socket. Stop shuts it down to end a read that FreeRDP blocks in. */
    pthread_mutex_t lock;
    bool stopping;
    int connection;
    pthread_t thread;
    char *certificate, *key;
    bool pausable;
    atomic_uint refreshes, whole_refreshes, pauses;
    atomic_bool activated, ended;
};

static RMTestRDPServer *server_of(rdpContext *context) { return context->peer->ContextExtra; }

static BOOL refresh_rect(rdpContext *context, BYTE count, const RECTANGLE_16 *areas) {
    RMTestRDPServer *s = server_of(context);
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    bool whole = false;
    /* Bounds are inclusive. */
    for (BYTE i = 0; i < count; i++)
        whole = whole || (areas[i].left == 0 && areas[i].top == 0 && areas[i].right + 1u >= width &&
                          areas[i].bottom + 1u >= height);
    atomic_fetch_add(&s->refreshes, 1);
    if (whole)
        atomic_fetch_add(&s->whole_refreshes, 1);
    return TRUE;
}

/* FreeRDP's own handler sends a reply, which would wake the client. */
static BOOL suppress_output(rdpContext *context, BYTE allow, const RECTANGLE_16 *area) {
    (void)area;
    if (!allow)
        atomic_fetch_add(&server_of(context)->pauses, 1);
    return TRUE;
}

static BOOL post_connect(freerdp_peer *peer) {
    (void)peer;
    return TRUE;
}

static BOOL activate(freerdp_peer *peer) {
    atomic_store(&server_of(peer->context)->activated, true);
    return TRUE;
}

static bool configure(freerdp_peer *peer, const RMTestRDPServer *s) {
    rdpSettings *settings = peer->context->settings;
    rdpPrivateKey *key = freerdp_key_new_from_file(s->key);
    rdpCertificate *certificate = freerdp_certificate_new_from_file(s->certificate);
    /* The settings take ownership of the identity. */
    if (!key || !freerdp_settings_set_pointer_len(settings, FreeRDP_RdpServerRsaKey, key, 1)) {
        freerdp_key_free(key);
        freerdp_certificate_free(certificate);
        return false;
    }
    if (!certificate || !freerdp_settings_set_pointer_len(settings, FreeRDP_RdpServerCertificate, certificate, 1)) {
        freerdp_certificate_free(certificate);
        return false;
    }
    /* Without Suppress Output the client never pauses updates. */
    if (!freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RefreshRect, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_SuppressOutput, s->pausable) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32))
        return false;
    peer->PostConnect = post_connect;
    peer->Activate = activate;
    peer->context->update->RefreshRect = refresh_rect;
    peer->context->update->SuppressOutput = suppress_output;
    return true;
}

static void serve_connection(RMTestRDPServer *s, int connection) {
    freerdp_peer *peer = freerdp_peer_new(connection);
    if (!peer) {
        close(connection);
        return;
    }
    peer->ContextExtra = s;
    if (freerdp_peer_context_new(peer)) {
        if (configure(peer, s) && peer->Initialize(peer)) {
            for (;;) {
                HANDLE handles[32] = { 0 };
                DWORD count = peer->GetEventHandles(peer, handles, 31);
                if (!count)
                    break;
                handles[count++] = s->stop;
                if (WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED ||
                    WaitForSingleObject(s->stop, 0) == WAIT_OBJECT_0 || !peer->CheckFileDescriptor(peer))
                    break;
            }
            peer->Disconnect(peer);
        }
        freerdp_peer_context_free(peer);
    }
    freerdp_peer_free(peer);
}

static void *serve(void *argument) {
    RMTestRDPServer *s = argument;
    struct pollfd waits[2] = { { s->listener, POLLIN, 0 }, { s->wake[0], POLLIN, 0 } };
    if (poll(waits, 2, -1) > 0 && (waits[0].revents & POLLIN) && !(waits[1].revents & POLLIN)) {
        const int connection = accept(s->listener, NULL, NULL);
        if (connection >= 0) {
            pthread_mutex_lock(&s->lock);
            if (!s->stopping)
                s->connection = dup(connection);
            const bool serving = s->connection >= 0;
            pthread_mutex_unlock(&s->lock);
            if (!serving) {
                close(connection);
            } else {
                serve_connection(s, connection);
                /* The duplicate must not hold the connection open after FreeRDP has finished with it. */
                pthread_mutex_lock(&s->lock);
                close(s->connection);
                s->connection = -1;
                pthread_mutex_unlock(&s->lock);
            }
        }
    }
    atomic_store(&s->ended, true);
    return NULL;
}

static void release(RMTestRDPServer *s) {
    if (s->listener >= 0)
        close(s->listener);
    for (int i = 0; i < 2; i++)
        if (s->wake[i] >= 0)
            close(s->wake[i]);
    if (s->connection >= 0)
        close(s->connection);
    if (s->stop)
        (void)CloseHandle(s->stop);
    pthread_mutex_destroy(&s->lock);
    free(s->certificate);
    free(s->key);
    free(s);
}

/* Runs before the first server, so before any client thread in the process. FreeRDP sends even a loopback
 * connection through a proxy from the environment. */
static void prepare_process(void) {
    unsetenv("https_proxy");
    unsetenv("HTTPS_PROXY");
}

RMTestRDPServer *rm_test_rdp_server_start(const char *certificate_path, const char *key_path, bool pausable) {
    static pthread_once_t prepared = PTHREAD_ONCE_INIT;
    if (!certificate_path || !key_path || !winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT))
        return NULL;
    pthread_once(&prepared, prepare_process);
    RMTestRDPServer *s = calloc(1, sizeof(*s));
    if (!s)
        return NULL;
    s->listener = s->wake[0] = s->wake[1] = s->connection = -1;
    s->pausable = pausable;
    pthread_mutex_init(&s->lock, NULL);
    s->certificate = strdup(certificate_path);
    s->key = strdup(key_path);
    s->stop = CreateEvent(NULL, TRUE, FALSE, NULL);
    struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET,
                                   .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t length = sizeof(address);
    s->listener = socket(AF_INET, SOCK_STREAM, 0);
    if (!s->certificate || !s->key || !s->stop || s->listener < 0 || pipe(s->wake) != 0 ||
        bind(s->listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(s->listener, 1) != 0 ||
        getsockname(s->listener, (struct sockaddr *)&address, &length) != 0 ||
        pthread_create(&s->thread, NULL, serve, s) != 0) {
        release(s);
        return NULL;
    }
    s->port = ntohs(address.sin_port);
    return s;
}

uint16_t rm_test_rdp_server_port(const RMTestRDPServer *s) { return s->port; }
bool rm_test_rdp_server_activated(const RMTestRDPServer *s) { return atomic_load(&s->activated); }
uint32_t rm_test_rdp_server_refreshes(const RMTestRDPServer *s) { return atomic_load(&s->refreshes); }
uint32_t rm_test_rdp_server_whole_refreshes(const RMTestRDPServer *s) { return atomic_load(&s->whole_refreshes); }
uint32_t rm_test_rdp_server_pauses(const RMTestRDPServer *s) { return atomic_load(&s->pauses); }
bool rm_test_rdp_server_ended(const RMTestRDPServer *s) { return atomic_load(&s->ended); }

void rm_test_rdp_server_stop(RMTestRDPServer *s) {
    if (!s)
        return;
    (void)write(s->wake[1], "x", 1);
    (void)SetEvent(s->stop);
    pthread_mutex_lock(&s->lock);
    s->stopping = true;
    if (s->connection >= 0)
        (void)shutdown(s->connection, SHUT_RDWR);
    pthread_mutex_unlock(&s->lock);
    pthread_join(s->thread, NULL);
    release(s);
}
