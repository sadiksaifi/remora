#ifndef REMORA_VIDEO_H
#define REMORA_VIDEO_H
#include "CFreeRDPBridge.h"
#define WITH_OPAQUE_SETTINGS
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/client/rdpgfx.h>
#pragma clang diagnostic pop

/* Sends H.264 surface commands to the video callbacks, which convert them on the GPU into the
 * desktop texture, and leaves every other graphics command to FreeRDP's GDI. On the GPU path it skips
 * the blank placeholder that Windows sends before a redraw (rm_display_skip_placeholder). A GPU-drawn area of
 * a surface is stale in the surface's CPU pixels. Before any other command reads or writes that
 * surface, its stale areas are read back from the desktop texture, and before any mapping, every
 * surface's are. Graphics channel thread only. */
typedef struct RMVideo RMVideo;
/* NULL when the callbacks have no video_frame, which keeps the CPU path. */
RMVideo *rm_video_new(const RMRDPCallbacks *callbacks, void *user);
void rm_video_free(RMVideo *video);
/* Wraps the GDI callbacks of a newly connected graphics channel. Forgets all stale areas. */
void rm_video_attach(RMVideo *video, RdpgfxClientContext *gfx);
/* Forgets all stale areas when the GDI and its surfaces go away. */
void rm_video_detach(RMVideo *video);
RMVideo *rm_rdp_video(RMRDPSession *session);
#endif
