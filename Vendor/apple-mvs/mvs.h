/*
 * Remora Apple MVS decoder. Experimental production profile.
 *
 * Decoder for Apple Remote Desktop / Screen Sharing encoding 1011 ("MVS").
 *
 * This file is a C port of noVNC-ARD's MVS decoder, licensed under the
 * Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/):
 *   https://github.com/peetinc/noVNC-ARD
 *   commit d699293635083c9e0c30c8f9480993865653772a
 *   ard/decoders/mvs.js, mvs-bitstream.js, mvs-rice.js, mvs-huffman.js,
 *   mvs-tables.js, mvs-idct.js
 * The MVS decoder entered noVNC-ARD in commits b2f8986 and ed528e3.
 *
 * The inverse DCT follows jpeg_idct_islow from the Independent JPEG Group's
 * jidctint.c, as ported by mvs-idct.js. This software is based in part on
 * the work of the Independent JPEG Group. See
 * Vendor/licenses/libjpeg-turbo-README.ijg and libjpeg-turbo-LICENSE.md.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Differences from the JavaScript decoder:
 *  - Every condition the JavaScript decoder logs and continues past is a
 *    typed failure here. The caller ends the session.
 *  - Tiles are decoded straight into the caller's framebuffer. Match tiles
 *    copy from it. noVNC-ARD keeps a second RGBA framebuffer only because
 *    it cannot read back its canvas.
 *  - Cache slots render on every load. noVNC-ARD's rendered-slot cache is
 *    an optimisation with the same output.
 */
#ifndef REMORA_APPLE_MVS_H
#define REMORA_APPLE_MVS_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    MVS_OK = 0,
    MVS_E_ARGUMENT = 1,      /* null pointer or a surface that cannot hold the rect */
    MVS_E_ALLOCATION = 2,
    MVS_E_SIZE = 3,          /* framebuffer larger than MVS_MAX_DIMENSION, or size overflow */
    MVS_E_RECT = 4,          /* rect leaves the framebuffer */
    MVS_E_EMPTY = 5,         /* zero-length payload */
    MVS_E_UPDATE_TYPE = 6,   /* first payload byte is not 0, 1 or 2 */
    MVS_E_QUANT_LENGTH = 7,  /* quantization update is not 129 bytes */
    MVS_E_SHORT = 8,         /* full update shorter than its 6-byte header */
    MVS_E_BODY_OFFSET = 9,
    MVS_E_OVERRUN = 10,      /* a bitstream read past its end */
    MVS_E_RICE = 11,         /* unary prefix longer than MVS_MAX_RICE_PREFIX */
    MVS_E_HUFFMAN = 12,      /* no K.5 code within 16 bits */
    MVS_E_REPEAT = 13,       /* repeat tile without a previous DCT tile */
    MVS_E_BASELINE = 14,     /* partial DCT tile without a full-update baseline */
    MVS_E_CACHE_SLOT = 15,   /* cache slot 0, >= 65000, or never written */
    MVS_E_HEADER_MARKER = 16,
    MVS_E_BODY_MARKER = 17,
    MVS_E_PARTIAL_MARKER = 18,
} mvs_error;

enum {
    MVS_MAX_DIMENSION = 16384,
    MVS_MAX_RICE_PREFIX = 1024,
    MVS_CACHE_SLOTS = 65000,
    MVS_CACHE_ENTRY_BYTES = 99,
};

/* A 32-bit-per-pixel framebuffer owned by the caller. Pixels are stored as
 * host-order uint32 values with red, green and blue at the given shifts and
 * alpha (0xff) in the remaining byte. */
typedef struct {
    uint8_t *pixels;
    uint32_t width, height;
    size_t stride;           /* bytes per row, at least 4 * width */
    unsigned red_shift, green_shift, blue_shift;
} mvs_surface;

typedef enum { MVS_KIND_QUANT = 2, MVS_KIND_FULL = 0, MVS_KIND_PARTIAL = 1 } mvs_kind;

/* Counts of one decoded rect. Tile counts follow the wire tile codes. */
typedef struct {
    mvs_kind kind;
    uint32_t full_tiles[8];      /* full update tile types 0..7 */
    uint32_t partial_tiles[4];   /* partial codes 0 skip, 1 DCT, 2 match, 3 cache */
    uint32_t copy_skipped;       /* match tiles whose source the reference also skips */
    uint32_t wide_idct;          /* transforms with a dequantized coefficient beyond +-2^15 */
} mvs_stats;

/* Called for each tile written into the surface. */
typedef void (*mvs_written_fn)(void *context, uint32_t x, uint32_t y, uint32_t w, uint32_t h);

typedef struct mvs_decoder mvs_decoder;

mvs_decoder *mvs_create(void);
void mvs_destroy(mvs_decoder *decoder);

/* Decodes one rect payload (the bytes after the u32 length). A failure
 * leaves the decoder unusable for the session: the caller disconnects. */
mvs_error mvs_decode(mvs_decoder *decoder, const mvs_surface *surface,
                     uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                     const uint8_t *payload, size_t length,
                     mvs_written_fn written, void *context, mvs_stats *stats);

/* Bytes the decoder holds for its current framebuffer size, computed with
 * checked arithmetic. Fills the parts when the pointers are non-null. */
size_t mvs_memory_bytes(const mvs_decoder *decoder, size_t *descriptor_bytes,
                        size_t *cache_bytes, size_t *tiles);

/* Descriptor bytes for a framebuffer, or 0 on overflow. For the memory test. */
size_t mvs_descriptor_bytes_for(uint32_t width, uint32_t height, size_t *tiles);

/* libjpeg islow transform of 64 dequantized natural-order coefficients.
 * Exposed for the DC-flat equality test. */
void mvs_idct8x8(const int32_t block[64], uint8_t out[64]);
uint8_t mvs_idct_flat(int32_t dc);

#endif
