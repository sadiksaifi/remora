#ifndef REMORA_FREERDP_REFERENCE_H
#define REMORA_FREERDP_REFERENCE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* FreeRDP's own CPU conversion of decoded H.264 pictures, for tests that compare the GPU path with it.
 * Layouts: 0 AVC420, 1 AVC444 luma, 2 AVC444 chroma v1, 3 AVC444 chroma v2. */
typedef struct RMReference RMReference;
typedef struct {
    uint16_t left, top, right, bottom;
} RMReferenceRectangle;

/* The YUV444 planes start zeroed, have luma_stride bytes per row, and persist across decodes, as FreeRDP's do. */
RMReference *rm_reference_new(uint32_t surface_width, uint32_t surface_height, uint32_t luma_stride);
void rm_reference_free(RMReference *reference);
/* Converts one picture's rectangles into BGRX pixels. */
bool rm_reference_decode(
    RMReference *reference, int layout, const uint8_t *const planes[3], const uint32_t strides[3],
    uint32_t picture_height, const RMReferenceRectangle *rectangles, size_t count, uint8_t *pixels, uint32_t stride);
#endif
