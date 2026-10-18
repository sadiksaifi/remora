#include "display.h"
#include <freerdp/client/disp.h>
#include <winpr/sysinfo.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* Display Control callbacks run on the dynamic-channel worker. The lock protects
 * the channel, caps, a single-slot command queue, and the display update switch.
 * Only process sends layouts and Suppress Output; callbacks to Swift always run after unlocking. */
struct RMDisplay {
    rdpContext *context;
    RMRDPCallbacks callbacks;
    void *user;
    pthread_mutex_t lock;
    HANDLE wake;
    os_log_t log;
    DispClientContext *channel;
    uint32_t max_monitors;
    uint64_t max_area;
    bool available, reported_available;
    bool queued, waiting, sent;
    unsigned retries;
    uint64_t last_sent;
    DISPLAY_CONTROL_MONITOR_LAYOUT desired, last_layout;
    uint32_t observed_width, observed_height;
    bool observed_requested;
    /* What the client wants and what the server was last told. Servers start with updates on. */
    bool updates_wanted, updates_sent, refresh_pending;
};

static UINT display_caps(DispClientContext *channel, UINT32 monitors, UINT32 a, UINT32 b) {
    RMDisplay *d = channel->custom;
    pthread_mutex_lock(&d->lock);
    d->max_monitors = monitors;
    /* The caps specify a total pixel area, not independent width/height limits. */
    d->max_area = (uint64_t)monitors * a;
    d->max_area = b && d->max_area > UINT64_MAX / b ? UINT64_MAX : d->max_area * b;
    d->available = monitors > 0 && d->max_area >= 200 * 200;
    os_log_info(d->log, "Display Control caps: monitors=%u, max area=%llu", monitors, (unsigned long long)d->max_area);
    SetEvent(d->wake);
    pthread_mutex_unlock(&d->lock);
    return CHANNEL_RC_OK;
}

static void channel_connected(void *context, const ChannelConnectedEventArgs *event) {
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) != 0)
        return;
    RMDisplay *d = rm_rdp_display(context);
    DispClientContext *channel = event->pInterface;
    pthread_mutex_lock(&d->lock);
    d->channel = channel;
    channel->custom = d;
    channel->DisplayControlCaps = display_caps;
    pthread_mutex_unlock(&d->lock);
}

static void channel_disconnected(void *context, const ChannelDisconnectedEventArgs *event) {
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) != 0)
        return;
    RMDisplay *d = rm_rdp_display(context);
    pthread_mutex_lock(&d->lock);
    d->channel = NULL;
    d->available = d->queued = d->waiting = d->sent = false;
    memset(&d->desired, 0, sizeof(d->desired));
    DispClientContext *channel = event->pInterface;
    channel->DisplayControlCaps = NULL;
    channel->custom = NULL;
    SetEvent(d->wake);
    pthread_mutex_unlock(&d->lock);
}

RMDisplay *rm_display_new(rdpContext *context, const RMRDPCallbacks *callbacks, void *user) {
    RMDisplay *d = calloc(1, sizeof(*d));
    if (!d)
        return NULL;
    d->context = context;
    d->callbacks = *callbacks;
    d->user = user;
    d->updates_wanted = d->updates_sent = true;
    if (pthread_mutex_init(&d->lock, NULL) != 0) {
        free(d);
        return NULL;
    }
    d->log = os_log_create("dev.sadiksaifi.Remora", "Display");
    d->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!d->wake || PubSub_SubscribeChannelConnected(context->pubSub, channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(context->pubSub, channel_disconnected) < 0) {
        PubSub_UnsubscribeChannelConnected(context->pubSub, channel_connected);
        PubSub_UnsubscribeChannelDisconnected(context->pubSub, channel_disconnected);
        rm_display_free(d);
        return NULL;
    }
    return d;
}

void rm_display_free(RMDisplay *d) {
    if (!d)
        return;
    if (d->wake) CloseHandle(d->wake);
    os_release(d->log);
    pthread_mutex_destroy(&d->lock);
    free(d);
}

HANDLE rm_display_event(RMDisplay *d) { return d->wake; }

uint64_t rm_rdp_max_resize_area(RMRDPSession *session) {
    RMDisplay *d = rm_rdp_display(session);
    pthread_mutex_lock(&d->lock);
    const uint64_t area = d->available ? d->max_area : 0;
    pthread_mutex_unlock(&d->lock);
    return area;
}

void rm_rdp_request_resize(RMRDPSession *session, uint32_t width, uint32_t height, double scale) {
    if (!width || !height || !isfinite(scale) || scale < 1 || scale > 5)
        return;
    RMDisplay *d = rm_rdp_display(session);
    pthread_mutex_lock(&d->lock);
    if (d->available) {
        width = width < 200 ? 200 : width > 8192 ? 8192 : width & ~1u;
        height = height < 200 ? 200 : height > 8192 ? 8192 : height;
        if ((uint64_t)width * height > d->max_area) {
            const double factor = sqrt((double)d->max_area / ((double)width * height));
            width = (uint32_t)(width * factor) & ~1u;
            height = (uint32_t)(height * factor);
            if (width < 200) width = 200;
            if (height < 200) height = 200;
            if ((uint64_t)width * height > d->max_area)
                height = (uint32_t)(d->max_area / width);
            if (height < 200) {
                height = 200;
                width = (uint32_t)(d->max_area / height) & ~1u;
            }
        }
        DISPLAY_CONTROL_MONITOR_LAYOUT layout = {
            .Flags = DISPLAY_CONTROL_MONITOR_PRIMARY, .Width = width, .Height = height,
            /* Match SDL3's single-window monitor attributes (sdl_window.cpp). */
            .PhysicalWidth = width, .PhysicalHeight = height,
            .DesktopScaleFactor = (UINT32)lround(scale * 100), .DeviceScaleFactor = 100
        };
        if (memcmp(&layout, &d->desired, sizeof(layout)) != 0 ||
            (!d->waiting && !d->queued &&
             (width != d->observed_width || height != d->observed_height))) {
            d->desired = layout;
            d->queued = true;
            d->retries = 0;
            SetEvent(d->wake);
        }
    }
    pthread_mutex_unlock(&d->lock);
}

void rm_rdp_set_display_updates(RMRDPSession *session, bool enabled) {
    RMDisplay *d = rm_rdp_display(session);
    pthread_mutex_lock(&d->lock);
    if (d->updates_wanted != enabled) {
        d->updates_wanted = enabled;
        /* A brief suppression can be coalesced before process runs. Keep the refresh
         * owed to the next observer even when the server never saw the off state. */
        if (enabled) d->refresh_pending = true;
        SetEvent(d->wake);
    }
    pthread_mutex_unlock(&d->lock);
}

void rm_display_reconnected(RMDisplay *d) {
    pthread_mutex_lock(&d->lock);
    d->updates_sent = true;
    SetEvent(d->wake);
    pthread_mutex_unlock(&d->lock);
}

/* FreeRDP sends nothing when the server lacks suppressOutputSupport, and the server keeps
 * sending updates. A failed write surfaces through the event loop like any other. */
static void send_display_updates(RMDisplay *d, bool allow) {
    rdpContext *context = d->context;
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    /* TS_RECTANGLE16 bounds are inclusive. */
    const RECTANGLE_16 desktop = {
        .left = 0, .top = 0,
        .right = (UINT16)(width > 0 ? width - 1 : 0), .bottom = (UINT16)(height > 0 ? height - 1 : 0)
    };
    /* Force a real off-to-on transition even if the previous suppression was coalesced. */
    BOOL sent = context->update->SuppressOutput(context, 0, NULL);
    if (sent && allow)
        sent = context->update->SuppressOutput(context, 1, &desktop);
    if (sent && allow)
        sent = context->update->RefreshRect(context, 1, &desktop);
    os_log_info(d->log, "Display updates: %{public}s, server support=%d, status=%d", allow ? "on" : "off",
                freerdp_settings_get_bool(context->settings, FreeRDP_SuppressOutput), sent);
}

DWORD rm_display_process(RMDisplay *d) {
    pthread_mutex_lock(&d->lock);
    ResetEvent(d->wake);
    const bool updates_changed = d->updates_wanted != d->updates_sent || (d->updates_wanted && d->refresh_pending);
    d->refresh_pending = false;
    const bool updates = d->updates_wanted;
    d->updates_sent = updates;
    const bool changed = d->available != d->reported_available;
    const bool available = d->available;
    d->reported_available = available;
    const uint64_t now = GetTickCount64();
    DWORD timeout = INFINITE;
    if (available && d->channel && (d->queued || (d->waiting && d->retries < 5))) {
        /* SDL3: >=500 ms between sends; retry at 1000 ms, at most five times.
         * Unlike SDL's equal-layout suppression, a missing response resends the
         * last layout. A queued command always supersedes an older retry. */
        const uint64_t due = d->sent ? d->last_sent + (d->queued ? 500 : 1000) : now;
        if (now >= due) {
            d->last_layout = d->desired;
            const UINT status = d->channel->SendMonitorLayout(d->channel, 1, &d->last_layout);
            os_log_info(d->log, "Display Control layout: %ux%u, scale=%u, retry=%u, status=%u",
                        d->last_layout.Width, d->last_layout.Height, d->last_layout.DesktopScaleFactor,
                        d->queued ? 0 : d->retries + 1, status);
            d->last_sent = now;
            d->sent = true;
            if (d->queued) d->retries = 0;
            else d->retries++;
            d->queued = false;
            d->waiting = true;
            /* Writes can fail during channel shutdown. Do not disconnect the
             * session for an optional resize; retry with the same bounded timer. */
            (void)status;
            if (d->retries < 5) timeout = 1000;
        } else {
            timeout = (DWORD)(due - now);
        }
        if (!d->queued && d->retries >= 5) timeout = INFINITE;
    }
    pthread_mutex_unlock(&d->lock);
    if (updates_changed)
        send_display_updates(d, updates);
    if (changed && d->callbacks.dynamic_resize)
        d->callbacks.dynamic_resize(d->user, available);
    return timeout;
}

bool rm_display_resized(RMDisplay *d, uint32_t width, uint32_t height) {
    pthread_mutex_lock(&d->lock);
    const bool duplicate = width == d->observed_width && height == d->observed_height;
    const bool requested = d->waiting || (duplicate && d->observed_requested);
    if (width == d->last_layout.Width && height == d->last_layout.Height) {
        d->waiting = false;
        SetEvent(d->wake);
    }
    d->observed_width = width;
    d->observed_height = height;
    d->observed_requested = requested;
    pthread_mutex_unlock(&d->lock);
    return requested;
}
