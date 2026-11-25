#ifndef REMORA_C_FREERDP_BRIDGE_H
#define REMORA_C_FREERDP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RMRDPSession RMRDPSession;

typedef enum {
    RMRDP_CLIPBOARD_NOT_READY,
    RMRDP_CLIPBOARD_UNKNOWN,
    RMRDP_CLIPBOARD_PENDING,
    RMRDP_CLIPBOARD_UNAVAILABLE,
    RMRDP_CLIPBOARD_REMOTE_TEXT,
    RMRDP_CLIPBOARD_FAILED,
    RMRDP_CLIPBOARD_LOCAL_TEXT
} RMRDPClipboardStatus;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *domain;
    const char *password; /* NULL means missing; empty is a supplied password. */
    const char *config_path;
    uint32_t width;
    uint32_t height;
    double scale_factor;
    uint32_t keyboard_layout;
    bool iso_keyboard;
    bool dynamic_resolution;
} RMRDPConfiguration;

typedef struct {
    int32_t x, y, width, height;
} RMRDPRectangle;

typedef enum {
    RMRDP_DISCONNECT_NONE,
    RMRDP_DISCONNECT_AUTHENTICATION_FAILED,
    RMRDP_DISCONNECT_CERTIFICATE_REJECTED,
    RMRDP_DISCONNECT_HOST_NOT_FOUND,
    RMRDP_DISCONNECT_CONNECTION_REFUSED,
    RMRDP_DISCONNECT_CONNECTION_TIMED_OUT,
    RMRDP_DISCONNECT_SERVER_ENDED_SESSION,
    RMRDP_DISCONNECT_PROTOCOL_ERROR,
    RMRDP_DISCONNECT_CANCELLED
} RMRDPDisconnectReason;

typedef enum { RMRDP_CURSOR_IMAGE, RMRDP_CURSOR_HIDDEN, RMRDP_CURSOR_DEFAULT } RMRDPCursorKind;

/* How a decoded H.264 picture reaches the desktop. YUV420 converts it directly. The others first merge it
 * into the surface's persistent 4:4:4 planes (MS-RDPEGFX 3.3.8.3), then convert those. */
typedef enum { RMRDP_VIDEO_YUV420, RMRDP_VIDEO_LUMA, RMRDP_VIDEO_CHROMA_V1, RMRDP_VIDEO_CHROMA_V2 } RMRDPVideoLayout;
typedef struct {
    uint16_t left, top, right, bottom;
} RMRDPVideoRectangle;
typedef struct {
    RMRDPVideoLayout layout;
    void *image; /* CVPixelBufferRef: three-plane I420 that Metal can read. */
    const RMRDPVideoRectangle *rectangles; /* Surface coordinates. */
    size_t count;
    uint32_t convert_height; /* Conversion clamps the rectangles to this height; merging does not. */
} RMRDPVideoPass;
typedef struct {
    uint16_t surface;
    uint32_t surface_width, surface_height;
    uint32_t origin_x, origin_y;           /* Desktop position of the surface's top-left pixel. */
    uint32_t visible_width, visible_height; /* Surface area that lands on the desktop. */
    uint32_t desktop_width, desktop_height;
    RMRDPVideoPass passes[2]; /* In order. */
    size_t pass_count;
} RMRDPVideoFrame;

typedef enum {
    RMRDP_VIDEO_DRAWN,
    /* Drawn, but a GPU error discarded the desktop's earlier GPU drawing since the last frame. */
    RMRDP_VIDEO_DRAWN_AFTER_LOSS,
    /* Not drawn. The update is dropped. */
    RMRDP_VIDEO_FAILED,
} RMRDPVideoResult;

/* Callbacks are synchronous and may run on different background threads.
 * All callback arguments are borrowed for the duration of that call. */
typedef struct {
    void (*connected)(void *user);
    void (*reconnecting)(void *user, uint32_t attempt);
    void (*disconnected)(void *user, RMRDPDisconnectReason reason, const char *message);
    void (*desktop_size)(void *user, uint32_t width, uint32_t height, bool requested);
    void (*dynamic_resize)(void *user, bool available);
    /* BGRA32 bytes, alpha ignored. Copy pixels before returning. */
    void (*frame)(void *user, const uint8_t *pixels, uint32_t width, uint32_t height,
                  uint32_t stride, const RMRDPRectangle *rectangles, size_t count);
    /* While held, frame and video_frame still change the desktop but publish nothing. Releasing
     * publishes what changed meanwhile as one frame. Session thread. */
    void (*hold)(void *user, bool held);
    /* Straight-alpha BGRA32, tightly packed. Copy before returning. */
    void (*cursor)(void *user, RMRDPCursorKind kind, const uint8_t *pixels,
                   uint32_t width, uint32_t height, uint32_t hotspot_x, uint32_t hotspot_y);
    void (*clipboard_changed)(void *user, uint64_t revision, RMRDPClipboardStatus status, const char *text);
    /* On success supply malloc-owned strings in all three outputs; the bridge takes ownership.
     * On cancellation return false and leave outputs NULL. */
    bool (*credentials)(void *user, const char *username, const char *domain, bool rejected,
                        char **new_username, char **new_domain, char **new_password);
    /* old_fingerprint is NULL for a new certificate. true accepts AND stores the certificate. */
    bool (*trust)(void *user, const char *host, uint16_t port, const char *subject,
                  const char *issuer, const char *fingerprint, const char *old_fingerprint);
    /* Optional, with video_read. Draws H.264 on the GPU into the desktop instead of through frame.
     * The images are borrowed: retain them to use them after returning. */
    RMRDPVideoResult (*video_frame)(void *user, const RMRDPVideoFrame *frame);
    /* Copies desktop rectangles, as BGRA32, after all earlier drawing, into an image whose top-left
     * pixel is the desktop pixel at origin_x, origin_y. */
    bool (*video_read)(void *user, const RMRDPVideoRectangle *rectangles, size_t count, uint32_t origin_x,
                       uint32_t origin_y, uint8_t *pixels, uint32_t stride);
    /* The surface ID was created or deleted, so the GPU state kept for it, such as its 4:4:4 planes,
     * belongs to no surface. A reconnect creates surfaces with the IDs of the old ones. */
    void (*video_surface_reset)(void *user, uint16_t surface);
} RMRDPCallbacks;

/* Copies configuration and callbacks. Create/run/free on the owned session thread.
 * The caller must keep user alive through free. NULL means invalid configuration or allocation failure. */
RMRDPSession *rm_rdp_create(const RMRDPConfiguration *config, const RMRDPCallbacks *callbacks,
                           void *user);
/* Single-use; blocks through connection, event loop and channel cleanup. */
void rm_rdp_run(RMRDPSession *session);
/* Cross-thread cancellation. Does not free; run must return before free. */
void rm_rdp_abort(RMRDPSession *session);
void rm_rdp_free(RMRDPSession *session);
/* Session-worker only, after run and before free. Empty when no failed TCP endpoint was retained. */
const char *rm_rdp_failure_address(RMRDPSession *session);
uint16_t rm_rdp_failure_port(RMRDPSession *session);
/* Thread-safe enqueue only. The caller excludes free until the call returns. */
uint64_t rm_rdp_max_resize_area(RMRDPSession *session);
void rm_rdp_request_resize(RMRDPSession *session, uint32_t width, uint32_t height, double scale);
/* Thread-safe enqueue. Pauses the server with Suppress Output (MS-RDPBCGR 2.2.11.3) once updates have
 * stayed off for two seconds, and only when the server also supports Refresh Rect. Enabling a paused
 * server asks it to redraw the whole desktop. Survives automatic reconnection. */
void rm_rdp_set_display_updates(RMRDPSession *session, bool enabled);
/* Thread-safe. Asks the server to redraw the whole desktop with Refresh Rect, once, when it supports that. */
void rm_rdp_request_refresh(RMRDPSession *session);
/* True from enabling the updates of a paused server until its redraw has been published. */
bool rm_rdp_awaits_redraw(RMRDPSession *session);
void rm_rdp_key(RMRDPSession *session, uint16_t key, bool down);
void rm_rdp_pointer(RMRDPSession *session, uint16_t x, uint16_t y, uint8_t buttons);
void rm_rdp_wheel(RMRDPSession *session, int32_t vertical, int32_t horizontal);
void rm_rdp_synchronize(RMRDPSession *session, uint8_t locks);
/* Transport recovery releases both sources. Focus changes release only human input. */
void rm_rdp_release_all(RMRDPSession *session);
void rm_rdp_release_human(RMRDPSession *session);
/* Agent input has one request owner per session. IDs and acknowledgments are local
 * protocol submission receipts, not acknowledgments from the remote application.
 * Cancellation is checked for every event, including an already detached drain list. */
typedef enum { RMRDP_AGENT_SCAN, RMRDP_AGENT_POINTER, RMRDP_AGENT_WHEEL,
               RMRDP_AGENT_UNICODE, RMRDP_AGENT_PAUSE, RMRDP_AGENT_RELEASE } RMRDPAgentEventKind;
typedef struct {
    RMRDPAgentEventKind kind;
    uint32_t scancode;
    bool down;
    uint16_t x, y, utf16[2];
    uint8_t buttons, units;
    int32_t vertical, horizontal;
} RMRDPAgentEvent;
/* Capability bits: Unicode 1, extended buttons 2, horizontal wheel 4. */
uint8_t rm_rdp_input_capabilities(RMRDPSession *session);
uint64_t rm_rdp_agent_begin(RMRDPSession *session);
uint64_t rm_rdp_agent_send(RMRDPSession *session, uint64_t request, RMRDPAgentEvent event);
void rm_rdp_agent_cancel(RMRDPSession *session, uint64_t request);
/* 0 pending, 1 submitted, -1 cancelled/replaced, -2 protocol submission failed. */
int rm_rdp_agent_status(RMRDPSession *session, uint64_t request, uint64_t sequence, bool cleanup);
/* Copies NUL-terminated UTF-8 text and wakes the session thread. */
void rm_rdp_set_local_clipboard(RMRDPSession *session, const char *text);
/* Zero means unsupported. Uses WinPR's Apple table plus documented corrections. */
uint32_t rm_rdp_scancode(uint16_t key, bool iso_keyboard);
uint32_t rm_rdp_keyboard_layout(const char *name);

#ifdef __cplusplus
}
#endif
#endif
