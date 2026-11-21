#include "CFreeRDPReference.h"
#include <stdlib.h>
#define WITH_OPAQUE_SETTINGS
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/codec/color.h>
#include <freerdp/codec/yuv.h>
#include <freerdp/primitives.h>
#include <freerdp/settings.h>
#pragma clang diagnostic pop

struct RMReference {
    YUV_CONTEXT *yuv;
    BYTE *planes[3];
    UINT32 strides[3];
};

RMReference *rm_reference_new(uint32_t surface_width, uint32_t surface_height, uint32_t luma_stride) {
    RMReference *reference = calloc(1, sizeof(*reference));
    if (!reference) return NULL;
    reference->yuv = yuv_context_new(FALSE, THREADING_FLAGS_DISABLE_THREADS);
    /* avc444_ensure_buffer: the height padded to 16, plus 16 rows. */
    const size_t rows = ((surface_height + 15) / 16) * 16 + 16;
    for (int plane = 0; plane < 3; plane++) {
        reference->planes[plane] = calloc(rows, luma_stride);
        reference->strides[plane] = luma_stride;
    }
    if (!reference->yuv || !reference->planes[0] || !reference->planes[1] || !reference->planes[2] ||
        !yuv_context_reset(reference->yuv, surface_width, surface_height)) {
        rm_reference_free(reference);
        return NULL;
    }
    return reference;
}

void rm_reference_free(RMReference *reference) {
    if (!reference) return;
    yuv_context_free(reference->yuv);
    for (int plane = 0; plane < 3; plane++) free(reference->planes[plane]);
    free(reference);
}

bool rm_reference_decode(
    RMReference *reference, int layout, const uint8_t *const planes[3], const uint32_t strides[3],
    uint32_t picture_height, const RMReferenceRectangle *rectangles, size_t count, uint8_t *pixels, uint32_t stride) {
    const BYTE *source[3] = {planes[0], planes[1], planes[2]};
    const UINT32 sourceStrides[3] = {strides[0], strides[1], strides[2]};
    const RECTANGLE_16 *rects = (const RECTANGLE_16 *)rectangles;
    if (layout == 0)
        return yuv420_context_decode(
            reference->yuv, source, sourceStrides, picture_height, PIXEL_FORMAT_BGRX32, pixels, stride, rects, (UINT32)count);
    const BYTE type = layout == 1 ? AVC444_LUMA : layout == 2 ? AVC444_CHROMAv1 : AVC444_CHROMAv2;
    return yuv444_context_decode(
        reference->yuv, type, source, sourceStrides, picture_height, reference->planes, reference->strides,
        PIXEL_FORMAT_BGRX32, pixels, stride, rects, (UINT32)count);
}
