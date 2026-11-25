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
/* Updates stay on this long after their last use, so back-to-back uses never pause the server. */
#define PAUSE_DELAY_MS 2000
/* A pause lasts at least this long, so every frame the server sent before pausing has arrived
 * and the first frame after the resume answers it. */
#define MINIMUM_PAUSE_MS 1000
/* Windows answers a resume with a blank placeholder of the whole desktop, then the redraw 3 to 44 ms later.
 * So the redraw counts as arrived this long after the first frame that answers the resume. */
#define REDRAW_HOLD_MS 100
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
    bool updates_wanted, updates_sent;
    /* The server honors both Suppress Output and Refresh Rect. */
    bool pausable;
    /* When updates stopped being wanted, and when the server was told to pause. */
    uint64_t unwanted_at, paused_at;
    /* A resume of a paused server owes a redraw. redraw_sent: its request is on the wire.
     * redraw_due: when the redraw counts as arrived, set by the first frame after the request, otherwise 0. */
    bool redraw_owed, redraw_sent;
    uint64_t redraw_due;
    /* A whole-desktop Refresh Rect is wanted, for example after pixels drawn on the GPU were lost. */
    bool refresh_wanted;
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
    d->log = os_log_create("com.peblon.remora", "Display");
    d->wake = CreateEvent(NULL, true, false, NULL);
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
        if (!enabled) {
            d->unwanted_at = GetTickCount64();
        } else if (!d->updates_sent) {
            /* Only a server that was told to pause has stale frames to replace. */
            d->redraw_owed = true;
            d->redraw_sent = false;
            d->redraw_due = 0;
        }
        SetEvent(d->wake);
    }
    pthread_mutex_unlock(&d->lock);
}

/* Pause only a server that also redraws on request. One that honors Suppress Output alone, such as
 * GNOME Remote Desktop, sends nothing after a pause unless its screen changed meanwhile, so the client
 * could not tell a current frame from a missing one. Such a server keeps sending updates. */
void rm_display_connected(RMDisplay *d) {
    const rdpSettings *settings = d->context->settings;
    const bool suppress = freerdp_settings_get_bool(settings, FreeRDP_SuppressOutput);
    const bool refresh = freerdp_settings_get_bool(settings, FreeRDP_RefreshRect);
    os_log_info(d->log, "Display updates: server suppress=%d, refresh=%d", suppress, refresh);
    pthread_mutex_lock(&d->lock);
    d->pausable = suppress && refresh;
    d->updates_sent = true;
    /* A new connection draws the whole desktop. A redraw that arrived before it keeps its deadline. */
    d->redraw_sent = d->redraw_owed;
    SetEvent(d->wake);
    pthread_mutex_unlock(&d->lock);
}

void rm_display_frame(RMDisplay *d) {
    pthread_mutex_lock(&d->lock);
    if (d->redraw_sent && !d->redraw_due) {
        d->redraw_due = GetTickCount64() + REDRAW_HOLD_MS;
        SetEvent(d->wake);
    }
    pthread_mutex_unlock(&d->lock);
}

void rm_display_request_refresh(RMDisplay *d) {
    pthread_mutex_lock(&d->lock);
    d->refresh_wanted = true;
    SetEvent(d->wake);
    pthread_mutex_unlock(&d->lock);
}

void rm_rdp_request_refresh(RMRDPSession *session) { rm_display_request_refresh(rm_rdp_display(session)); }

bool rm_rdp_awaits_redraw(RMRDPSession *session) {
    RMDisplay *d = rm_rdp_display(session);
    pthread_mutex_lock(&d->lock);
    const bool owed = d->redraw_owed;
    pthread_mutex_unlock(&d->lock);
    return owed;
}

static RECTANGLE_16 whole_desktop(const rdpContext *context) {
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    /* TS_RECTANGLE16 bounds are inclusive. */
    return (RECTANGLE_16){
        .left = 0, .top = 0,
        .right = (UINT16)(width > 0 ? width - 1 : 0), .bottom = (UINT16)(height > 0 ? height - 1 : 0)
    };
}

/* A failed write surfaces through the event loop like any other. */
static void send_display_updates(RMDisplay *d, bool allow) {
    rdpContext *context = d->context;
    const RECTANGLE_16 desktop = whole_desktop(context);
    const BOOL sent = allow
        ? context->update->SuppressOutput(context, 1, &desktop) && context->update->RefreshRect(context, 1, &desktop)
        : context->update->SuppressOutput(context, 0, NULL);
    os_log_info(d->log, "Display updates: %{public}s, status=%d", allow ? "on" : "off", sent);
}

DWORD rm_display_process(RMDisplay *d) {
    pthread_mutex_lock(&d->lock);
    ResetEvent(d->wake);
    const uint64_t now = GetTickCount64();
    const bool updates = d->updates_wanted || !d->pausable;
    bool updates_changed = false;
    DWORD updates_timeout = INFINITE;
    if (updates != d->updates_sent) {
        const uint64_t due = updates ? d->paused_at + MINIMUM_PAUSE_MS : d->unwanted_at + PAUSE_DELAY_MS;
        if (now >= due) {
            updates_changed = true;
            d->updates_sent = updates;
            if (!updates) d->paused_at = now;
        } else {
            updates_timeout = (DWORD)(due - now);
        }
    }
    if (d->redraw_due && now >= d->redraw_due) {
        d->redraw_owed = d->redraw_sent = false;
        d->redraw_due = 0;
    } else if (d->redraw_due && d->redraw_due - now < updates_timeout) {
        updates_timeout = (DWORD)(d->redraw_due - now);
    }
    /* A server that still sends updates redraws now, during the pause delay too. A paused server keeps the
     * request until it resumes, and the resume's own Refresh Rect serves it. */
    const bool refresh = d->refresh_wanted && d->updates_sent && !updates_changed;
    if (refresh || updates_changed)
        d->refresh_wanted = false;
    const bool changed = d->available != d->reported_available;
    const bool available = d->available;
    d->reported_available = available;
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
    if (updates_changed) {
        send_display_updates(d, updates);
        if (updates) {
            /* Set only after the write: a frame another thread finishes before it is not the redraw. */
            pthread_mutex_lock(&d->lock);
            d->redraw_sent = d->redraw_owed;
            d->redraw_due = 0;
            pthread_mutex_unlock(&d->lock);
        }
    }
    if (refresh && freerdp_settings_get_bool(d->context->settings, FreeRDP_RefreshRect)) {
        const RECTANGLE_16 desktop = whole_desktop(d->context);
        const BOOL sent = d->context->update->RefreshRect(d->context, 1, &desktop);
        os_log_info(d->log, "Refresh of the whole desktop requested, status=%d", sent);
    }
    if (changed && d->callbacks.dynamic_resize)
        d->callbacks.dynamic_resize(d->user, available);
    return timeout < updates_timeout ? timeout : updates_timeout;
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
