#ifndef REMORA_FREERDP_GRAPHICS_H
#define REMORA_FREERDP_GRAPHICS_H
#include "CFreeRDPBridge.h"

/* A session that never connects, with FreeRDP's GDI and a graphics channel that has no server behind it,
 * so tests can send graphics commands through Remora's video module as a server would. Surfaces are BGRX.
 * Each function returns FreeRDP's channel status, 0 on success. */
typedef struct RMGraphics RMGraphics;
typedef enum { RMGRAPHICS_AVC420, RMGRAPHICS_AVC444, RMGRAPHICS_AVC444V2 } RMGraphicsCodec;

/* refresh_rect says whether the server honors Refresh Rect, as Windows does and GNOME does not. */
RMGraphics *rm_graphics_new(uint32_t width, uint32_t height, bool refresh_rect, const RMRDPCallbacks *callbacks,
                            void *user);
void rm_graphics_free(RMGraphics *graphics);
RMRDPSession *rm_graphics_session(RMGraphics *graphics);

uint32_t rm_graphics_create_surface(RMGraphics *graphics, uint16_t surface, uint16_t width, uint16_t height);
uint32_t rm_graphics_delete_surface(RMGraphics *graphics, uint16_t surface);
uint32_t rm_graphics_map(RMGraphics *graphics, uint16_t surface, uint32_t x, uint32_t y);
/* bgr is 0xRRGGBB. */
uint32_t rm_graphics_fill(RMGraphics *graphics, uint16_t surface, RMRDPVideoRectangle area, uint32_t bgr);
uint32_t rm_graphics_copy(RMGraphics *graphics, uint16_t from, RMRDPVideoRectangle area, uint16_t to, uint16_t x,
                          uint16_t y);
/* Cache slots run from 1 to 16. */
uint32_t rm_graphics_cache(RMGraphics *graphics, uint16_t surface, RMRDPVideoRectangle area, uint16_t slot);
uint32_t rm_graphics_restore(RMGraphics *graphics, uint16_t slot, uint16_t surface, uint16_t x, uint16_t y);
/* Every picture in the command is the same 64x64 IDR frame, filled with 0x3080C0. AVC444 sends both views. */
uint32_t rm_graphics_h264(RMGraphics *graphics, uint16_t surface, RMGraphicsCodec codec,
                          const RMRDPVideoRectangle *rectangles, size_t count);
/* A planar bitmap of one color, 0xRRGGBB. */
uint32_t rm_graphics_planar(RMGraphics *graphics, uint16_t surface, RMRDPVideoRectangle area, uint32_t bgr);
/* Outside a frame, FreeRDP sends each command's CPU drawing to the desktop at once. Inside one, it sends the
 * surfaces' CPU drawing at the end. */
uint32_t rm_graphics_start_frame(RMGraphics *graphics);
uint32_t rm_graphics_end_frame(RMGraphics *graphics);

/* 0xRRGGBB. */
uint32_t rm_graphics_surface_pixel(RMGraphics *graphics, uint16_t surface, uint32_t x, uint32_t y);
uint32_t rm_graphics_desktop_pixel(RMGraphics *graphics, uint32_t x, uint32_t y);

/* Whether the session thread has been woken to run the display's step, which clears the wakeup. */
bool rm_graphics_display_woken(RMGraphics *graphics);
/* Runs the display's session-thread step, then returns how many Refresh Rect requests the session has sent. */
unsigned rm_graphics_refreshes(RMGraphics *graphics);
/* How many Suppress Output requests that pause updates the session has sent. */
unsigned rm_graphics_pauses(RMGraphics *graphics);
/* The next pause request draws an H.264 frame on the surface while it is written, as a frame that another thread
 * finishes during the write. */
void rm_graphics_draw_on_pause(RMGraphics *graphics, uint16_t surface);
/* The session connects again, as after an automatic reconnection. */
void rm_graphics_reconnect(RMGraphics *graphics);
#endif
