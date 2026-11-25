#include "CFreeRDPGraphics.h"
#include "../../Sources/CFreeRDPBridge/display.h"
#include "../../Sources/CFreeRDPBridge/video.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/gdi/gdi.h>
#include <freerdp/codec/planar.h>
#include <freerdp/gdi/gfx.h>
#pragma clang diagnostic pop

#define MAX_SURFACES 64
#define MAX_CACHE_SLOTS 16

/* A 64x64 baseline IDR frame of 0x3080C0, from x264 with its SEI removed. */
static const BYTE idr[] = {
    0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xc0, 0x0a, 0xdc, 0x42, 0x6c, 0x04, 0x40, 0x00, 0x00, 0x03,
    0x00, 0x40, 0x00, 0x00, 0x0c, 0x83, 0xc4, 0x89, 0xe0, 0x00, 0x00, 0x00, 0x01, 0x68, 0xce, 0x0f,
    0x2c, 0x80, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x04, 0xbc, 0x46, 0x28, 0x00, 0x08, 0xd3,
    0xc7, 0x00, 0x01, 0x2b, 0x28, 0xe0, 0x00, 0x25, 0x67, 0x27, 0x27, 0x27, 0x5d, 0x75, 0xd7, 0x5d,
    0x75, 0xd7, 0x5d, 0x75, 0xd7, 0x80,
};

struct RMGraphics {
    RMRDPSession *session;
    rdpContext *context;
    RdpgfxClientContext gfx;
    void *surfaces[MAX_SURFACES];
    void *cache[MAX_CACHE_SLOTS];
    unsigned refreshes, pauses;
    /* The next pause request draws an H.264 frame on this surface before it returns, or 0 for none. */
    uint16_t draw_on_pause;
    UINT32 frame;
    RMGraphics *next;
};

/* FreeRDP's update callbacks get only the context, so they find their harness here. */
static pthread_mutex_t all_lock = PTHREAD_MUTEX_INITIALIZER;
static RMGraphics *all;

static RMGraphics *graphics_of(rdpContext *context) {
    pthread_mutex_lock(&all_lock);
    RMGraphics *g = all;
    while (g && g->context != context)
        g = g->next;
    pthread_mutex_unlock(&all_lock);
    return g;
}

static BOOL refresh_rect(rdpContext *context, BYTE count, const RECTANGLE_16 *areas) {
    (void)count;
    (void)areas;
    graphics_of(context)->refreshes++;
    return TRUE;
}

static BOOL suppress_output(rdpContext *context, BYTE allow, const RECTANGLE_16 *area) {
    (void)area;
    RMGraphics *g = graphics_of(context);
    if (!allow) {
        g->pauses++;
        const uint16_t surface = g->draw_on_pause;
        g->draw_on_pause = 0;
        const RMRDPVideoRectangle rectangle = { 0, 0, 16, 16 };
        if (surface)
            (void)rm_graphics_h264(g, surface, RMGRAPHICS_AVC420, &rectangle, 1);
    }
    return TRUE;
}

/* The graphics channel's surface table, which FreeRDP's GDI expects the channel to keep. */
static RMGraphics *owner(RdpgfxClientContext *gfx) { return (RMGraphics *)((BYTE *)gfx - offsetof(RMGraphics, gfx)); }

static UINT set_surface(RdpgfxClientContext *gfx, UINT16 id, void *data) {
    if (id >= MAX_SURFACES)
        return ERROR_INVALID_INDEX;
    owner(gfx)->surfaces[id] = data;
    return CHANNEL_RC_OK;
}

static void *get_surface(RdpgfxClientContext *gfx, UINT16 id) {
    return id < MAX_SURFACES ? owner(gfx)->surfaces[id] : NULL;
}

/* In ID order, so the end of a frame sends lower IDs to the desktop first. */
static UINT surface_ids(RdpgfxClientContext *gfx, UINT16 **ids, UINT16 *count) {
    RMGraphics *g = owner(gfx);
    *ids = calloc(MAX_SURFACES, sizeof(**ids));
    *count = 0;
    if (!*ids)
        return CHANNEL_RC_NO_MEMORY;
    for (UINT16 id = 0; id < MAX_SURFACES; id++)
        if (g->surfaces[id])
            (*ids)[(*count)++] = id;
    return CHANNEL_RC_OK;
}

/* Cache slots start at 1, as in MS-RDPEGFX. */
static UINT set_cache(RdpgfxClientContext *gfx, UINT16 slot, void *data) {
    if (slot == 0 || slot > MAX_CACHE_SLOTS)
        return ERROR_INVALID_INDEX;
    owner(gfx)->cache[slot - 1] = data;
    return CHANNEL_RC_OK;
}

static void *get_cache(RdpgfxClientContext *gfx, UINT16 slot) {
    return slot > 0 && slot <= MAX_CACHE_SLOTS ? owner(gfx)->cache[slot - 1] : NULL;
}

RMGraphics *rm_graphics_new(uint32_t width, uint32_t height, bool refresh, const RMRDPCallbacks *callbacks,
                            void *user) {
    const RMRDPConfiguration config = { .host = "localhost", .port = 3389, .username = "", .domain = "",
                                        .password = "", .config_path = "/nonexistent", .width = width,
                                        .height = height, .scale_factor = 1 };
    RMGraphics *g = calloc(1, sizeof(*g));
    if (!g)
        return NULL;
    g->session = rm_rdp_create(&config, callbacks, user);
    /* The session's context comes first in it. */
    g->context = (rdpContext *)g->session;
    if (!g->session || !rm_rdp_video(g->session)) {
        rm_graphics_free(g);
        return NULL;
    }
    /* The order caches that GDI registers with are made while connecting. Graphics pipeline commands use none. */
    rdpSettings *settings = g->context->settings;
    if (!freerdp_settings_set_bool(settings, FreeRDP_SuppressOutput, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_RefreshRect, refresh) ||
        !freerdp_settings_set_bool(settings, FreeRDP_DeactivateClientDecoding, TRUE) ||
        !gdi_init(g->context->instance, PIXEL_FORMAT_BGRA32) ||
        !freerdp_settings_set_bool(settings, FreeRDP_DeactivateClientDecoding, FALSE)) {
        rm_graphics_free(g);
        return NULL;
    }
    g->context->update->RefreshRect = refresh_rect;
    g->context->update->SuppressOutput = suppress_output;
    g->gfx.GetSurfaceIds = surface_ids;
    g->gfx.SetSurfaceData = set_surface;
    g->gfx.GetSurfaceData = get_surface;
    g->gfx.SetCacheSlotData = set_cache;
    g->gfx.GetCacheSlotData = get_cache;
    if (!gdi_graphics_pipeline_init(g->context->gdi, &g->gfx)) {
        rm_graphics_free(g);
        return NULL;
    }
    rm_video_attach(rm_rdp_video(g->session), &g->gfx);
    rm_display_connected(rm_rdp_display(g->session));
    pthread_mutex_lock(&all_lock);
    g->next = all;
    all = g;
    pthread_mutex_unlock(&all_lock);
    return g;
}

void rm_graphics_free(RMGraphics *g) {
    if (!g)
        return;
    pthread_mutex_lock(&all_lock);
    for (RMGraphics **link = &all; *link; link = &(*link)->next)
        if (*link == g) {
            *link = g->next;
            break;
        }
    pthread_mutex_unlock(&all_lock);
    if (g->gfx.custom) {
        for (UINT16 slot = 1; slot <= MAX_CACHE_SLOTS; slot++) {
            const RDPGFX_EVICT_CACHE_ENTRY_PDU evict = { slot };
            if (g->cache[slot - 1])
                (void)g->gfx.EvictCacheEntry(&g->gfx, &evict);
        }
        for (UINT16 id = 0; id < MAX_SURFACES; id++)
            if (g->surfaces[id])
                (void)rm_graphics_delete_surface(g, id);
        gdi_graphics_pipeline_uninit(g->context->gdi, &g->gfx);
    }
    if (g->session) {
        rm_video_detach(rm_rdp_video(g->session));
        gdi_free(g->context->instance);
        rm_rdp_free(g->session);
    }
    free(g);
}

RMRDPSession *rm_graphics_session(RMGraphics *g) { return g->session; }

uint32_t rm_graphics_create_surface(RMGraphics *g, uint16_t surface, uint16_t width, uint16_t height) {
    const RDPGFX_CREATE_SURFACE_PDU pdu = { surface, width, height, GFX_PIXEL_FORMAT_XRGB_8888 };
    return g->gfx.CreateSurface(&g->gfx, &pdu);
}

uint32_t rm_graphics_delete_surface(RMGraphics *g, uint16_t surface) {
    const RDPGFX_DELETE_SURFACE_PDU pdu = { surface };
    return g->gfx.DeleteSurface(&g->gfx, &pdu);
}

uint32_t rm_graphics_map(RMGraphics *g, uint16_t surface, uint32_t x, uint32_t y) {
    const RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU pdu = { surface, 0, x, y };
    return g->gfx.MapSurfaceToOutput(&g->gfx, &pdu);
}

static RECTANGLE_16 rectangle(RMRDPVideoRectangle area) { return (RECTANGLE_16){ area.left, area.top, area.right, area.bottom }; }

uint32_t rm_graphics_fill(RMGraphics *g, uint16_t surface, RMRDPVideoRectangle area, uint32_t bgr) {
    RECTANGLE_16 rect = rectangle(area);
    const RDPGFX_SOLID_FILL_PDU pdu = { surface, { bgr & 0xff, (bgr >> 8) & 0xff, (bgr >> 16) & 0xff, 0xff }, 1, &rect };
    return g->gfx.SolidFill(&g->gfx, &pdu);
}

uint32_t rm_graphics_copy(RMGraphics *g, uint16_t from, RMRDPVideoRectangle area, uint16_t to, uint16_t x, uint16_t y) {
    RDPGFX_POINT16 point = { x, y };
    const RDPGFX_SURFACE_TO_SURFACE_PDU pdu = { from, to, rectangle(area), 1, &point };
    return g->gfx.SurfaceToSurface(&g->gfx, &pdu);
}

uint32_t rm_graphics_cache(RMGraphics *g, uint16_t surface, RMRDPVideoRectangle area, uint16_t slot) {
    const RDPGFX_SURFACE_TO_CACHE_PDU pdu = { surface, slot, slot, rectangle(area) };
    return g->gfx.SurfaceToCache(&g->gfx, &pdu);
}

uint32_t rm_graphics_restore(RMGraphics *g, uint16_t slot, uint16_t surface, uint16_t x, uint16_t y) {
    RDPGFX_POINT16 point = { x, y };
    const RDPGFX_CACHE_TO_SURFACE_PDU pdu = { slot, surface, 1, &point };
    return g->gfx.CacheToSurface(&g->gfx, &pdu);
}

uint32_t rm_graphics_h264(RMGraphics *g, uint16_t surface, RMGraphicsCodec codec, const RMRDPVideoRectangle *rectangles,
                          size_t count) {
    RECTANGLE_16 *rects = calloc(count ? count : 1, sizeof(*rects));
    RDPGFX_H264_QUANT_QUALITY *quality = calloc(count ? count : 1, sizeof(*quality));
    if (!rects || !quality) {
        free(rects);
        free(quality);
        return CHANNEL_RC_NO_MEMORY;
    }
    RDPGFX_SURFACE_COMMAND cmd = { .surfaceId = surface, .format = PIXEL_FORMAT_BGRX32,
                                   .left = UINT16_MAX, .top = UINT16_MAX };
    for (size_t i = 0; i < count; i++) {
        rects[i] = rectangle(rectangles[i]);
        cmd.left = MIN(cmd.left, rects[i].left);
        cmd.top = MIN(cmd.top, rects[i].top);
        cmd.right = MAX(cmd.right, rects[i].right);
        cmd.bottom = MAX(cmd.bottom, rects[i].bottom);
    }
    if (count == 0)
        cmd.left = cmd.top = 0;
    cmd.width = cmd.right - cmd.left;
    cmd.height = cmd.bottom - cmd.top;
    const RDPGFX_AVC420_BITMAP_STREAM stream = { { (UINT32)count, rects, quality }, sizeof(idr), (BYTE *)idr };
    RDPGFX_AVC444_BITMAP_STREAM both = { sizeof(idr), 0, { stream, stream } };
    switch (codec) {
    case RMGRAPHICS_AVC420:
        cmd.codecId = RDPGFX_CODECID_AVC420;
        cmd.extra = (void *)&stream;
        break;
    case RMGRAPHICS_AVC444:
    case RMGRAPHICS_AVC444V2:
        cmd.codecId = codec == RMGRAPHICS_AVC444 ? RDPGFX_CODECID_AVC444 : RDPGFX_CODECID_AVC444v2;
        cmd.extra = &both;
        break;
    }
    const UINT status = g->gfx.SurfaceCommand(&g->gfx, &cmd);
    free(rects);
    free(quality);
    return status;
}

uint32_t rm_graphics_start_frame(RMGraphics *g) {
    const RDPGFX_START_FRAME_PDU pdu = { 0, ++g->frame };
    return g->gfx.StartFrame(&g->gfx, &pdu);
}

uint32_t rm_graphics_planar(RMGraphics *g, uint16_t surface, RMRDPVideoRectangle area, uint32_t bgr) {
    const UINT32 width = area.right - area.left, height = area.bottom - area.top;
    BYTE *pixels = calloc((size_t)width * height, 4);
    BITMAP_PLANAR_CONTEXT *planar =
        freerdp_bitmap_planar_context_new(PLANAR_FORMAT_HEADER_NA | PLANAR_FORMAT_HEADER_RLE, width, height);
    UINT32 size = 0;
    BYTE *data = NULL;
    if (pixels && planar) {
        for (size_t i = 0; i < (size_t)width * height; i++)
            memcpy(pixels + i * 4, (const BYTE[]){ bgr & 0xff, (bgr >> 8) & 0xff, (bgr >> 16) & 0xff, 0xff }, 4);
        data = freerdp_bitmap_compress_planar(planar, pixels, PIXEL_FORMAT_BGRX32, width, height, width * 4, NULL, &size);
    }
    UINT status = CHANNEL_RC_NO_MEMORY;
    if (data) {
        const RDPGFX_SURFACE_COMMAND cmd = { .surfaceId = surface, .codecId = RDPGFX_CODECID_PLANAR,
                                             .format = PIXEL_FORMAT_BGRX32, .left = area.left, .top = area.top,
                                             .right = area.right, .bottom = area.bottom, .width = width,
                                             .height = height, .length = size, .data = data };
        status = g->gfx.SurfaceCommand(&g->gfx, &cmd);
    }
    free(data);
    freerdp_bitmap_planar_context_free(planar);
    free(pixels);
    return status;
}

uint32_t rm_graphics_end_frame(RMGraphics *g) {
    const RDPGFX_END_FRAME_PDU pdu = { g->frame };
    return g->gfx.EndFrame(&g->gfx, &pdu);
}

static uint32_t pixel(const BYTE *data, UINT32 stride, uint32_t x, uint32_t y) {
    const BYTE *p = data + (size_t)y * stride + (size_t)x * 4;
    return (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
}

uint32_t rm_graphics_surface_pixel(RMGraphics *g, uint16_t surface, uint32_t x, uint32_t y) {
    const gdiGfxSurface *s = get_surface(&g->gfx, surface);
    return s && x < s->width && y < s->height ? pixel(s->data, s->scanline, x, y) : UINT32_MAX;
}

uint32_t rm_graphics_desktop_pixel(RMGraphics *g, uint32_t x, uint32_t y) {
    const rdpGdi *gdi = g->context->gdi;
    return x < (uint32_t)gdi->width && y < (uint32_t)gdi->height ? pixel(gdi->primary_buffer, gdi->stride, x, y)
                                                                   : UINT32_MAX;
}

bool rm_graphics_display_woken(RMGraphics *g) {
    return WaitForSingleObject(rm_display_event(rm_rdp_display(g->session)), 0) == WAIT_OBJECT_0;
}

void rm_graphics_reconnect(RMGraphics *g) { rm_display_connected(rm_rdp_display(g->session)); }

unsigned rm_graphics_refreshes(RMGraphics *g) {
    (void)rm_display_process(rm_rdp_display(g->session));
    return g->refreshes;
}

unsigned rm_graphics_pauses(RMGraphics *g) { return g->pauses; }

void rm_graphics_draw_on_pause(RMGraphics *g, uint16_t surface) { g->draw_on_pause = surface; }
