#include "video.h"
#include "display.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/codec/h264.h>
#include <freerdp/codec/region.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#pragma clang diagnostic pop
#include <CoreVideo/CoreVideo.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

#undef TRUE
#undef FALSE
#define TRUE true
#define FALSE false

/* gdi_surface_invalidate_rect bounds its region the same way: a region this fragmented is
 * replaced by its extents. */
#define MAX_STALE_RECTS 256

typedef struct {
    UINT16 surface;
    REGION16 region;
} RMStale;

struct RMVideo {
    RMRDPCallbacks callbacks;
    void *user;
    os_log_t log;
    RMStale *stale;
    size_t stale_count, stale_capacity;
    pcRdpgfxSurfaceCommand surface_command;
    pcRdpgfxSolidFill solid_fill;
    pcRdpgfxSurfaceToSurface surface_to_surface;
    pcRdpgfxSurfaceToCache surface_to_cache;
    pcRdpgfxCacheToSurface cache_to_surface;
    pcRdpgfxResetGraphics reset_graphics;
    pcRdpgfxCreateSurface create_surface;
    pcRdpgfxDeleteSurface delete_surface;
    pcRdpgfxMapSurfaceToOutput map_output;
    pcRdpgfxMapSurfaceToScaledOutput map_scaled_output;
    pcRdpgfxMapSurfaceToWindow map_window;
    pcRdpgfxMapSurfaceToScaledWindow map_scaled_window;
};

RMVideo *rm_video_new(const RMRDPCallbacks *callbacks, void *user) {
    if (!callbacks->video_frame || !callbacks->video_read)
        return NULL;
    RMVideo *video = calloc(1, sizeof(*video));
    if (!video)
        return NULL;
    video->callbacks = *callbacks;
    video->user = user;
    video->log = os_log_create("com.peblon.remora", "Video");
    return video;
}

static void forget_all(RMVideo *video) {
    for (size_t i = 0; i < video->stale_count; i++)
        region16_uninit(&video->stale[i].region);
    video->stale_count = 0;
}

void rm_video_free(RMVideo *video) {
    if (!video)
        return;
    forget_all(video);
    free(video->stale);
    free(video);
}

void rm_video_detach(RMVideo *video) {
    if (video)
        forget_all(video);
}

static RMVideo *video_of(RdpgfxClientContext *gfx) {
    rdpGdi *gdi = gfx->custom;
    return rm_rdp_video((RMRDPSession *)gdi->context);
}

static gdiGfxSurface *surface_of(RdpgfxClientContext *gfx, UINT32 id) {
    return gfx->GetSurfaceData(gfx, (UINT16)MIN(UINT16_MAX, id));
}

static RMStale *find_stale(RMVideo *video, UINT16 surface) {
    for (size_t i = 0; i < video->stale_count; i++)
        if (video->stale[i].surface == surface)
            return &video->stale[i];
    return NULL;
}

static void forget(RMVideo *video, UINT16 surface) {
    RMStale *stale = find_stale(video, surface);
    if (!stale)
        return;
    region16_uninit(&stale->region);
    *stale = video->stale[--video->stale_count];
}

static bool mark_stale(RMVideo *video, UINT16 surface, const RECTANGLE_16 *rect) {
    RMStale *stale = find_stale(video, surface);
    if (!stale) {
        if (video->stale_count == video->stale_capacity) {
            const size_t capacity = video->stale_capacity ? video->stale_capacity * 2 : 4;
            RMStale *grown = realloc(video->stale, capacity * sizeof(*grown));
            if (!grown)
                return false;
            video->stale = grown;
            video->stale_capacity = capacity;
        }
        stale = &video->stale[video->stale_count++];
        stale->surface = surface;
        region16_init(&stale->region);
    }
    if (!region16_union_rect(&stale->region, &stale->region, rect))
        return false;
    if (region16_n_rects(&stale->region) <= MAX_STALE_RECTS)
        return true;
    const RECTANGLE_16 extents = *region16_extents(&stale->region);
    region16_clear(&stale->region);
    return region16_union_rect(&stale->region, &stale->region, &extents);
}

/* The output area a surface drew into when its stale areas were rendered. */
static void visible_size(const rdpGdi *gdi, const gdiGfxSurface *surface, uint32_t *width, uint32_t *height) {
    *width = surface->outputOriginX < (UINT32)gdi->width ? MIN(surface->mappedWidth, (UINT32)gdi->width - surface->outputOriginX) : 0;
    *height = surface->outputOriginY < (UINT32)gdi->height ? MIN(surface->mappedHeight, (UINT32)gdi->height - surface->outputOriginY) : 0;
}

/* Copies the surface's GPU-drawn areas back into its CPU pixels, in one GPU round trip. Areas the GPU
 * clipped away outside the output keep their previous pixels, and so do all of them if the read fails:
 * FreeRDP never ends a session over a picture problem, and neither does this. */
static void read_back(RMVideo *video, RdpgfxClientContext *gfx, UINT16 id) {
    RMStale *stale = find_stale(video, id);
    if (!stale)
        return;
    gdiGfxSurface *surface = surface_of(gfx, id);
    if (surface) {
        rdpGdi *gdi = gfx->custom;
        uint32_t width = 0, height = 0;
        visible_size(gdi, surface, &width, &height);
        const RECTANGLE_16 visible = { 0, 0, (UINT16)MIN(UINT16_MAX, width), (UINT16)MIN(UINT16_MAX, height) };
        UINT32 count = 0;
        bool read = false;
        if (region16_intersect_rect(&stale->region, &stale->region, &visible)) {
            const RECTANGLE_16 *rects = region16_rects(&stale->region, &count);
            RMRDPVideoRectangle *areas = calloc(MAX(1, count), sizeof(*areas));
            const UINT32 x = surface->outputOriginX, y = surface->outputOriginY;
            for (UINT32 i = 0; areas && i < count; i++)
                areas[i] = (RMRDPVideoRectangle){ (uint16_t)(x + rects[i].left), (uint16_t)(y + rects[i].top),
                                                  (uint16_t)(x + rects[i].right), (uint16_t)(y + rects[i].bottom) };
            read = areas && (count == 0 || video->callbacks.video_read(video->user, areas, count, x, y, surface->data,
                                                                         surface->scanline));
            free(areas);
        }
        if (read)
            os_log_info(video->log, "Read back %u GPU-drawn rectangles of surface %u for a CPU command", count, id);
        else
            os_log_error(video->log, "Could not read back the GPU-drawn areas of surface %u; they keep older pixels", id);
    }
    forget(video, id);
}

static void read_back_all(RMVideo *video, RdpgfxClientContext *gfx) {
    while (video->stale_count > 0)
        read_back(video, gfx, video->stale[0].surface);
}

/* GPU drawing needs the surface to own its output area, unscaled, so the desktop texture holds
 * exactly its pixels and a read back returns them. The whole surface must land on the desktop,
 * because the GPU cannot keep pixels the desktop texture has no room for. Windows creates ARGB surfaces (BGRA32). FreeRDP's
 * H.264 conversion leaves their alpha untouched and the desktop is drawn opaque, so alpha is not kept.
 * AVC444 keeps 4:4:4 planes on the GPU and in FreeRDP separately, so when a surface moves between the
 * paths mid-stream, its colors are off until the server next sends the views that cover them. */
static bool draws_on_gpu(RdpgfxClientContext *gfx, const rdpGdi *gdi, const gdiGfxSurface *surface) {
    if (!surface->outputMapped || surface->windowMapped || surface->outputTargetWidth != surface->mappedWidth ||
        surface->outputTargetHeight != surface->mappedHeight || (surface->format != PIXEL_FORMAT_BGRX32 && surface->format != PIXEL_FORMAT_BGRA32) ||
        surface->outputOriginX + surface->mappedWidth > (UINT32)gdi->width ||
        surface->outputOriginY + surface->mappedHeight > (UINT32)gdi->height)
        return false;
    UINT16 *ids = NULL;
    UINT16 count = 0;
    if (gfx->GetSurfaceIds(gfx, &ids, &count) != CHANNEL_RC_OK)
        return false;
    bool alone = true;
    for (UINT16 i = 0; i < count && alone; i++) {
        if (ids[i] == surface->surfaceId)
            continue;
        const gdiGfxSurface *other = gfx->GetSurfaceData(gfx, ids[i]);
        if (!other || !other->outputMapped)
            continue;
        alone = other->outputOriginX >= surface->outputOriginX + surface->mappedWidth ||
                surface->outputOriginX >= other->outputOriginX + other->outputTargetWidth ||
                other->outputOriginY >= surface->outputOriginY + surface->mappedHeight ||
                surface->outputOriginY >= other->outputOriginY + other->outputTargetHeight;
    }
    free(ids);
    return alone;
}

static bool rects_within(const RECTANGLE_16 *rects, UINT32 count, UINT32 width, UINT32 height) {
    for (UINT32 i = 0; i < count; i++)
        if (rects[i].left > rects[i].right || rects[i].right > width || rects[i].top > rects[i].bottom ||
            rects[i].bottom > height)
            return false;
    return true;
}

typedef struct {
    CVPixelBufferRef image;
    const RDPGFX_H264_METABLOCK *meta;
    RMRDPVideoLayout layout;
} RMStream;

/* Mirrors log_decompress: 1 decoded, 0 no picture, negative failure. */
static int decode(H264_CONTEXT *h264, const RDPGFX_AVC420_BITMAP_STREAM *stream, const gdiGfxSurface *surface,
                  CVPixelBufferRef *image) {
    void *decoded = NULL;
    const int status = h264_decompress_image(h264, stream->data, stream->length, &decoded);
    if (status <= 0)
        return status;
    *image = decoded;
    const size_t width = CVPixelBufferGetWidth(*image), height = CVPixelBufferGetHeight(*image);
    const UINT32 count = stream->meta.numRegionRects;
    if (!rects_within(stream->meta.regionRects, count, (UINT32)width, (UINT32)height) ||
        !rects_within(stream->meta.regionRects, count, surface->width, surface->height))
        return -1015;
    return 1;
}

static RMRDPVideoRectangle *copy_rects(const RDPGFX_H264_METABLOCK *meta) {
    RMRDPVideoRectangle *rects = calloc(MAX(1, meta->numRegionRects), sizeof(*rects));
    for (UINT32 i = 0; rects && i < meta->numRegionRects; i++)
        rects[i] = (RMRDPVideoRectangle){ meta->regionRects[i].left, meta->regionRects[i].top,
                                         meta->regionRects[i].right, meta->regionRects[i].bottom };
    return rects;
}

/* Returns CHANNEL_RC_OK when the command was drawn or ignored as FreeRDP ignores it. */
static UINT draw_h264(RMVideo *video, RdpgfxClientContext *gfx, rdpGdi *gdi, gdiGfxSurface *surface,
                      const RDPGFX_SURFACE_COMMAND *cmd) {
    if (!surface->h264) {
        surface->h264 = h264_context_new(FALSE);
        if (!surface->h264)
            return ERROR_NOT_ENOUGH_MEMORY;
        if (!h264_context_reset(surface->h264, surface->width, surface->height))
            return ERROR_INTERNAL_ERROR;
    }
    if (cmd->left > cmd->right || cmd->right > surface->width || cmd->top > cmd->bottom || cmd->bottom > surface->height)
        return ERROR_INVALID_DATA;
    if (!cmd->extra)
        return ERROR_INTERNAL_ERROR;

    RMStream streams[2] = { { 0 } };
    size_t count = 0;
    if (cmd->codecId == RDPGFX_CODECID_AVC420) {
        const RDPGFX_AVC420_BITMAP_STREAM *stream = cmd->extra;
        streams[count++] = (RMStream){ NULL, &stream->meta, RMRDP_VIDEO_YUV420 };
    } else {
        const RDPGFX_AVC444_BITMAP_STREAM *stream = cmd->extra;
        const RMRDPVideoLayout chroma =
            cmd->codecId == RDPGFX_CODECID_AVC444 ? RMRDP_VIDEO_CHROMA_V1 : RMRDP_VIDEO_CHROMA_V2;
        switch (stream->LC) {
        case 0:
            streams[count++] = (RMStream){ NULL, &stream->bitstream[0].meta, RMRDP_VIDEO_LUMA };
            streams[count++] = (RMStream){ NULL, &stream->bitstream[1].meta, chroma };
            break;
        case 1: streams[count++] = (RMStream){ NULL, &stream->bitstream[0].meta, RMRDP_VIDEO_LUMA }; break;
        case 2: streams[count++] = (RMStream){ NULL, &stream->bitstream[0].meta, chroma }; break;
        default: return CHANNEL_RC_OK;
        }
    }

    UINT status = CHANNEL_RC_OK;
    RMRDPVideoFrame frame = { 0 };
    RMRDPVideoRectangle *rects[2] = { NULL, NULL };
    bool failed = false;
    for (size_t i = 0; i < count; i++) {
        const RDPGFX_H264_METABLOCK *meta = streams[i].meta;
        if (!meta->regionRects && meta->numRegionRects) {
            failed = true;
            break;
        }
        if (!rects_within(meta->regionRects, meta->numRegionRects, surface->width, surface->height)) {
            failed = true;
            break;
        }
    }
    for (size_t i = 0; i < count && !failed; i++) {
        const RDPGFX_AVC420_BITMAP_STREAM *stream =
            cmd->codecId == RDPGFX_CODECID_AVC420 ? cmd->extra
                                                  : &((const RDPGFX_AVC444_BITMAP_STREAM *)cmd->extra)->bitstream[i];
        const int decoded = decode(surface->h264, stream, surface, &streams[i].image);
        if (decoded < 0) {
            failed = true;
            break;
        }
        if (decoded == 0)
            continue;
        rects[i] = copy_rects(streams[i].meta);
        if (!rects[i]) {
            status = ERROR_NOT_ENOUGH_MEMORY;
            failed = true;
            break;
        }
        frame.passes[frame.pass_count++] = (RMRDPVideoPass){
            .layout = streams[i].layout,
            .image = streams[i].image,
            .rectangles = rects[i],
            .count = streams[i].meta->numRegionRects,
            .convert_height = MIN(surface->height, (uint32_t)CVPixelBufferGetHeight(streams[i].image)),
        };
    }
    if (failed) {
        if (status == CHANNEL_RC_OK)
            os_log_error(video->log, "H.264 decode failed on surface %u; the update is ignored", surface->surfaceId);
    } else if (frame.pass_count > 0) {
        frame.surface = surface->surfaceId;
        frame.surface_width = surface->width;
        frame.surface_height = surface->height;
        frame.origin_x = surface->outputOriginX;
        frame.origin_y = surface->outputOriginY;
        visible_size(gdi, surface, &frame.visible_width, &frame.visible_height);
        frame.desktop_width = (uint32_t)gdi->width;
        frame.desktop_height = (uint32_t)gdi->height;
        if (!video->callbacks.video_frame(video->user, &frame)) {
            os_log_error(video->log, "GPU drawing failed on surface %u; the update is ignored", surface->surfaceId);
        } else {
            for (size_t p = 0; p < frame.pass_count && status == CHANNEL_RC_OK; p++)
                for (size_t r = 0; r < frame.passes[p].count; r++) {
                    const RMRDPVideoRectangle *v = &frame.passes[p].rectangles[r];
                    const RECTANGLE_16 rect = { v->left, v->top, v->right, v->bottom };
                    if (rect.left < rect.right && rect.top < rect.bottom && !mark_stale(video, surface->surfaceId, &rect)) {
                        status = ERROR_NOT_ENOUGH_MEMORY;
                        break;
                    }
                }
            rm_display_frame(rm_rdp_display((RMRDPSession *)gdi->context));
        }
    }
    for (size_t i = 0; i < count; i++) {
        if (streams[i].image)
            CVPixelBufferRelease(streams[i].image);
        free(rects[i]);
    }
    return status;
}

static UINT surface_command(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_COMMAND *cmd) {
    RMVideo *video = video_of(gfx);
    const bool h264 = cmd->codecId == RDPGFX_CODECID_AVC420 || cmd->codecId == RDPGFX_CODECID_AVC444 ||
                      cmd->codecId == RDPGFX_CODECID_AVC444v2;
    EnterCriticalSection(&gfx->mux);
    gdiGfxSurface *surface = surface_of(gfx, cmd->surfaceId);
    rdpGdi *gdi = gfx->custom;
    UINT status = CHANNEL_RC_OK;
    if (h264 && surface && draws_on_gpu(gfx, gdi, surface)) {
        /* CPU drawing earlier in this frame reaches the desktop at the end of the frame, and would then
         * cover this newer picture. Send it now, so the desktop takes it before the GPU draws. */
        if (!region16_is_empty(&surface->invalidRegion))
            status = gfx->UpdateSurfaces(gfx);
        if (status == CHANNEL_RC_OK)
            status = draw_h264(video, gfx, gdi, surface, cmd);
        LeaveCriticalSection(&gfx->mux);
        return status;
    }
    read_back(video, gfx, (UINT16)MIN(UINT16_MAX, cmd->surfaceId));
    LeaveCriticalSection(&gfx->mux);
    return video->surface_command(gfx, cmd);
}

/* Brings the given surfaces' CPU pixels up to date before a GDI command. */
static void before(RdpgfxClientContext *gfx, UINT16 first, UINT16 second) {
    RMVideo *video = video_of(gfx);
    EnterCriticalSection(&gfx->mux);
    read_back(video, gfx, first);
    read_back(video, gfx, second);
    LeaveCriticalSection(&gfx->mux);
}

/* A mapping can put a surface over GPU-drawn areas of others, and a read back of those areas would
 * then return its pixels. Every surface's CPU pixels are brought up to date first. */
static void before_mapping(RdpgfxClientContext *gfx) {
    RMVideo *video = video_of(gfx);
    EnterCriticalSection(&gfx->mux);
    read_back_all(video, gfx);
    LeaveCriticalSection(&gfx->mux);
}

static UINT solid_fill(RdpgfxClientContext *gfx, const RDPGFX_SOLID_FILL_PDU *pdu) {
    before(gfx, pdu->surfaceId, pdu->surfaceId);
    return video_of(gfx)->solid_fill(gfx, pdu);
}

static UINT surface_to_surface(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_TO_SURFACE_PDU *pdu) {
    before(gfx, pdu->surfaceIdSrc, pdu->surfaceIdDest);
    return video_of(gfx)->surface_to_surface(gfx, pdu);
}

static UINT surface_to_cache(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_TO_CACHE_PDU *pdu) {
    before(gfx, pdu->surfaceId, pdu->surfaceId);
    return video_of(gfx)->surface_to_cache(gfx, pdu);
}

static UINT cache_to_surface(RdpgfxClientContext *gfx, const RDPGFX_CACHE_TO_SURFACE_PDU *pdu) {
    before(gfx, pdu->surfaceId, pdu->surfaceId);
    return video_of(gfx)->cache_to_surface(gfx, pdu);
}

static UINT map_output(RdpgfxClientContext *gfx, const RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU *pdu) {
    before_mapping(gfx);
    return video_of(gfx)->map_output(gfx, pdu);
}

static UINT map_scaled_output(RdpgfxClientContext *gfx, const RDPGFX_MAP_SURFACE_TO_SCALED_OUTPUT_PDU *pdu) {
    before_mapping(gfx);
    return video_of(gfx)->map_scaled_output(gfx, pdu);
}

static UINT map_window(RdpgfxClientContext *gfx, const RDPGFX_MAP_SURFACE_TO_WINDOW_PDU *pdu) {
    before_mapping(gfx);
    return video_of(gfx)->map_window(gfx, pdu);
}

static UINT map_scaled_window(RdpgfxClientContext *gfx, const RDPGFX_MAP_SURFACE_TO_SCALED_WINDOW_PDU *pdu) {
    before_mapping(gfx);
    return video_of(gfx)->map_scaled_window(gfx, pdu);
}

/* A new or deleted surface ID has no GPU-drawn areas and no GPU state. */
static void reset(RdpgfxClientContext *gfx, UINT16 id) {
    RMVideo *video = video_of(gfx);
    EnterCriticalSection(&gfx->mux);
    forget(video, id);
    LeaveCriticalSection(&gfx->mux);
    if (video->callbacks.video_surface_reset)
        video->callbacks.video_surface_reset(video->user, id);
}

/* ResetGraphics fills every surface, so no GPU-drawn area remains. */
static UINT reset_graphics(RdpgfxClientContext *gfx, const RDPGFX_RESET_GRAPHICS_PDU *pdu) {
    RMVideo *video = video_of(gfx);
    EnterCriticalSection(&gfx->mux);
    forget_all(video);
    LeaveCriticalSection(&gfx->mux);
    return video->reset_graphics(gfx, pdu);
}

static UINT create_surface(RdpgfxClientContext *gfx, const RDPGFX_CREATE_SURFACE_PDU *pdu) {
    reset(gfx, pdu->surfaceId);
    return video_of(gfx)->create_surface(gfx, pdu);
}

static UINT delete_surface(RdpgfxClientContext *gfx, const RDPGFX_DELETE_SURFACE_PDU *pdu) {
    reset(gfx, pdu->surfaceId);
    return video_of(gfx)->delete_surface(gfx, pdu);
}

void rm_video_attach(RMVideo *video, RdpgfxClientContext *gfx) {
    if (!video)
        return;
    forget_all(video);
    video->surface_command = gfx->SurfaceCommand;
    video->solid_fill = gfx->SolidFill;
    video->surface_to_surface = gfx->SurfaceToSurface;
    video->surface_to_cache = gfx->SurfaceToCache;
    video->cache_to_surface = gfx->CacheToSurface;
    video->reset_graphics = gfx->ResetGraphics;
    video->create_surface = gfx->CreateSurface;
    video->delete_surface = gfx->DeleteSurface;
    video->map_output = gfx->MapSurfaceToOutput;
    video->map_scaled_output = gfx->MapSurfaceToScaledOutput;
    video->map_window = gfx->MapSurfaceToWindow;
    video->map_scaled_window = gfx->MapSurfaceToScaledWindow;
    gfx->SurfaceCommand = surface_command;
    gfx->SolidFill = solid_fill;
    gfx->SurfaceToSurface = surface_to_surface;
    gfx->SurfaceToCache = surface_to_cache;
    gfx->CacheToSurface = cache_to_surface;
    gfx->ResetGraphics = reset_graphics;
    gfx->CreateSurface = create_surface;
    gfx->DeleteSurface = delete_surface;
    gfx->MapSurfaceToOutput = map_output;
    gfx->MapSurfaceToScaledOutput = map_scaled_output;
    gfx->MapSurfaceToWindow = map_window;
    gfx->MapSurfaceToScaledWindow = map_scaled_window;
}
