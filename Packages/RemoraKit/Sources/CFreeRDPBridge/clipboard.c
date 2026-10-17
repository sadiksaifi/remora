#include "clipboard.h"
#include <freerdp/client/cliprdr.h>
#include <winpr/clipboard.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* Channel callbacks call cliprdr on FreeRDP's callback thread. Local changes
 * coalesce into one command, drained by the session thread. The mutex serializes
 * these calls with channel detach and protects the WinPR conversion clipboard.
 * Never call Swift while holding it: Swift's handle lock also guards enqueue. */
struct RMClipboard {
    pthread_mutex_t lock;
    HANDLE wake;
    CliprdrClientContext *channel;
    wClipboard *conversion;
    UINT32 utf8_format;
    RMRDPCallbacks callbacks;
    void *user;
    char *local_text;
    bool changed, ready, request_pending, want_remote;
    uint64_t generation, requested_generation;
};

static UINT send_formats(RMClipboard *c) {
    CLIPRDR_FORMAT format = { .formatId = CF_UNICODETEXT };
    const CLIPRDR_FORMAT_LIST list = {
        .numFormats = c->local_text ? 1 : 0,
        .formats = c->local_text ? &format : NULL
    };
    c->changed = false;
    return c->channel->ClientFormatList(c->channel, &list);
}

static UINT request_remote(RMClipboard *c) {
    if (!c->want_remote || c->request_pending)
        return CHANNEL_RC_OK;
    const CLIPRDR_FORMAT_DATA_REQUEST request = { .requestedFormatId = CF_UNICODETEXT };
    c->request_pending = true;
    c->requested_generation = c->generation;
    c->want_remote = false;
    const UINT rc = c->channel->ClientFormatDataRequest(c->channel, &request);
    if (rc != CHANNEL_RC_OK)
        c->request_pending = false;
    return rc;
}

static UINT monitor_ready(CliprdrClientContext *channel, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    RMClipboard *c = channel->custom;
    CLIPRDR_GENERAL_CAPABILITY_SET general = {
        .capabilitySetType = CB_CAPSTYPE_GENERAL,
        .capabilitySetLength = 12,
        .version = CB_CAPS_VERSION_2,
        .generalFlags = CB_USE_LONG_FORMAT_NAMES
    };
    const CLIPRDR_CAPABILITIES capabilities = {
        .cCapabilitiesSets = 1,
        .capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general
    };
    pthread_mutex_lock(&c->lock);
    UINT rc = channel->ClientCapabilities(channel, &capabilities);
    if (rc == CHANNEL_RC_OK) {
        c->ready = true;
        rc = send_formats(c);
    }
    pthread_mutex_unlock(&c->lock);
    return rc;
}

static UINT server_capabilities(CliprdrClientContext *channel, const CLIPRDR_CAPABILITIES *caps) {
    (void)channel;
    (void)caps; /* No files, locks, or other optional capabilities. */
    return CHANNEL_RC_OK;
}

static UINT server_format_list(CliprdrClientContext *channel, const CLIPRDR_FORMAT_LIST *list) {
    RMClipboard *c = channel->custom;
    pthread_mutex_lock(&c->lock);
    c->generation++;
    c->want_remote = false;
    free(c->local_text);
    c->local_text = NULL; /* Do not serve an old local offer after ownership changes. */
    c->changed = false;
    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT || list->formats[i].formatId == CF_TEXT)
            c->want_remote = true;
    }
    /* Even an image/file-only list must be acknowledged. */
    const CLIPRDR_FORMAT_LIST_RESPONSE response = { .common.msgFlags = CB_RESPONSE_OK };
    UINT rc = channel->ClientFormatListResponse(channel, &response);
    if (rc == CHANNEL_RC_OK)
        rc = request_remote(c);
    pthread_mutex_unlock(&c->lock);
    return rc;
}

static UINT server_format_list_response(CliprdrClientContext *channel,
                                        const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)channel;
    (void)response; /* No retry loop on a rejected offer. */
    return CHANNEL_RC_OK;
}

static UINT server_data_request(CliprdrClientContext *channel,
                                const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    RMClipboard *c = channel->custom;
    pthread_mutex_lock(&c->lock);
    UINT32 size = 0;
    void *data = NULL;
    const WCHAR empty = 0;
    if (request->requestedFormatId == CF_UNICODETEXT && c->local_text && !c->local_text[0]) {
        /* WinPR 3.32.2 rejects an empty UTF-8 conversion (wlen == 0). */
        size = sizeof(empty);
    } else if (request->requestedFormatId == CF_UNICODETEXT && c->local_text) {
        const size_t length = strlen(c->local_text) + 1;
        if (length <= UINT32_MAX &&
            ClipboardSetData(c->conversion, c->utf8_format, c->local_text, (UINT32)length))
            data = ClipboardGetData(c->conversion, CF_UNICODETEXT, &size);
    }
    const CLIPRDR_FORMAT_DATA_RESPONSE response = {
        .common.msgFlags = size ? CB_RESPONSE_OK : CB_RESPONSE_FAIL,
        .common.dataLen = size,
        .requestedFormatData = data ? data : (size ? (const BYTE *)&empty : NULL)
    };
    const UINT rc = channel->ClientFormatDataResponse(channel, &response);
    free(data);
    pthread_mutex_unlock(&c->lock);
    return rc;
}

static UINT server_data_response(CliprdrClientContext *channel,
                                 const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    RMClipboard *c = channel->custom;
    char *text = NULL;
    pthread_mutex_lock(&c->lock);
    if (c->request_pending) {
        /* Responses carry no request ID. Keep at most one outstanding request,
         * discard stale generations, then request the newest server offer. */
        if (c->requested_generation == c->generation &&
            (response->common.msgFlags & CB_RESPONSE_OK) &&
            response->requestedFormatData && response->common.dataLen >= 2 &&
            response->common.dataLen % 2 == 0 &&
            ClipboardSetData(c->conversion, CF_UNICODETEXT, response->requestedFormatData,
                             response->common.dataLen)) {
            UINT32 size = 0;
            text = ClipboardGetData(c->conversion, c->utf8_format, &size);
        }
        c->request_pending = false;
    }
    const UINT rc = request_remote(c);
    pthread_mutex_unlock(&c->lock);
    if (text && c->callbacks.remote_clipboard_text)
        c->callbacks.remote_clipboard_text(c->user, text);
    free(text);
    return rc;
}

RMClipboard *rm_clipboard_new(const RMRDPCallbacks *callbacks, void *user) {
    RMClipboard *c = calloc(1, sizeof(*c));
    if (!c)
        return NULL;
    if (pthread_mutex_init(&c->lock, NULL) != 0) {
        free(c);
        return NULL;
    }
    c->callbacks = *callbacks;
    c->user = user;
    c->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
    c->conversion = ClipboardCreate();
    if (c->conversion)
        c->utf8_format = ClipboardRegisterFormat(c->conversion, "UTF8_STRING");
    if (!c->wake || !c->conversion || !c->utf8_format) {
        rm_clipboard_free(c);
        return NULL;
    }
    return c;
}

void rm_clipboard_free(RMClipboard *c) {
    if (!c)
        return;
    /* Session teardown has joined all channel workers before reaching here. */
    ClipboardDestroy(c->conversion);
    if (c->wake) CloseHandle(c->wake);
    free(c->local_text);
    pthread_mutex_destroy(&c->lock);
    free(c);
}

HANDLE rm_clipboard_event(RMClipboard *c) { return c->wake; }

void rm_rdp_set_local_clipboard(RMRDPSession *session, const char *text) {
    if (!text)
        return;
    char *copy = strdup(text);
    if (!copy)
        return;
    RMClipboard *c = rm_rdp_clipboard(session);
    pthread_mutex_lock(&c->lock);
    free(c->local_text);
    c->local_text = copy;
    c->generation++;
    c->want_remote = false;
    c->changed = true;
    SetEvent(c->wake);
    pthread_mutex_unlock(&c->lock);
}

BOOL rm_clipboard_drain(RMClipboard *c) {
    pthread_mutex_lock(&c->lock);
    ResetEvent(c->wake);
    UINT rc = CHANNEL_RC_OK;
    if (c->channel && c->ready && c->changed)
        rc = send_formats(c);
    pthread_mutex_unlock(&c->lock);
    return rc == CHANNEL_RC_OK;
}

void rm_clipboard_channel_connected(void *context, const ChannelConnectedEventArgs *event) {
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) != 0)
        return;
    RMClipboard *c = rm_rdp_clipboard(context);
    CliprdrClientContext *channel = event->pInterface;
    pthread_mutex_lock(&c->lock);
    c->channel = channel;
    channel->custom = c;
    channel->MonitorReady = monitor_ready;
    channel->ServerCapabilities = server_capabilities;
    channel->ServerFormatList = server_format_list;
    channel->ServerFormatListResponse = server_format_list_response;
    channel->ServerFormatDataRequest = server_data_request;
    channel->ServerFormatDataResponse = server_data_response;
    pthread_mutex_unlock(&c->lock);
}

void rm_clipboard_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) != 0)
        return;
    RMClipboard *c = rm_rdp_clipboard(context);
    pthread_mutex_lock(&c->lock);
    if (c->channel) c->channel->custom = NULL;
    c->channel = NULL;
    c->ready = c->request_pending = c->want_remote = false;
    c->generation++;
    pthread_mutex_unlock(&c->lock);
}
