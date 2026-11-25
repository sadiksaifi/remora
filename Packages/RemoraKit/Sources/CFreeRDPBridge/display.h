#ifndef REMORA_DISPLAY_H
#define REMORA_DISPLAY_H
#include "CFreeRDPBridge.h"
#define WITH_OPAQUE_SETTINGS
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/freerdp.h>
#include <winpr/synch.h>
#pragma clang diagnostic pop

typedef struct RMDisplay RMDisplay;
RMDisplay *rm_display_new(rdpContext *context, const RMRDPCallbacks *callbacks, void *user);
void rm_display_free(RMDisplay *display);
HANDLE rm_display_event(RMDisplay *display);
/* Session thread only. Drains the latest resize and display update commands and returns the next deadline. */
DWORD rm_display_process(RMDisplay *display);
/* Session thread only. Call after each connect and reconnect, before the connected callback:
 * a new connection starts with display updates on, and its capabilities are final. */
void rm_display_connected(RMDisplay *display);
/* Call after each frame reaches the frame callback. */
void rm_display_frame(RMDisplay *display);
/* Any thread. True from a redraw request until the next frame reaches the frame callback. */
bool rm_display_redrawing(RMDisplay *display);
/* Graphics thread. Windows answers a resume with a placeholder before the redraw: a picture of the whole desktop in
 * one dark gray, with only a pointer in its corner. Call with a new picture that looks like one, before drawing it.
 * Returns true for the first such picture of a redraw, which is then not drawn. A later one is drawn, so a desktop
 * that really is blank still appears. */
bool rm_display_skip_placeholder(RMDisplay *display);
/* Any thread. Asks a server that honors Refresh Rect to send the whole desktop again, from the
 * session thread. A paused server gets the request when it resumes, which redraws anyway. */
void rm_display_request_refresh(RMDisplay *display);
/* Called by DesktopResize, including on the GFX worker. Returns the change's origin. */
bool rm_display_resized(RMDisplay *display, uint32_t width, uint32_t height);
RMDisplay *rm_rdp_display(RMRDPSession *session);
#endif
