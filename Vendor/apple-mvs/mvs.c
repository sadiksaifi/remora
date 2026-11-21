/*
 * Remora Apple MVS decoder. Experimental production profile.
 *
 * C port of noVNC-ARD's MVS (encoding 1011) decoder. Provenance, licence and
 * the differences from the JavaScript decoder are in mvs.h.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * The inverse DCT is derived from jidctint.c (jpeg_idct_islow) of the
 * Independent JPEG Group's software, through mvs-idct.js. This software is
 * based in part on the work of the Independent JPEG Group.
 */
#include "mvs.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

/* ---- Tables (mvs-tables.js, from libjpeg) ---- */

static const uint8_t ZIGZAG[64] = {
     0,  1,  8, 16,  9,  2,  3, 10, 17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

static const uint8_t DEFAULT_LUMA_QUANT[64] = {
    16, 11, 11, 14, 24, 22, 24, 33,
    11, 12, 11, 11, 26, 18, 19, 23,
    13, 13, 14, 24, 20, 21, 22, 28,
    13, 17, 14, 21, 23, 25, 34, 34,
    17, 22, 18, 25, 31, 32, 34, 44,
    24, 20, 17, 27, 35, 40, 44, 54,
    30, 35, 28, 30, 34, 44, 54, 64,
    35, 30, 33, 38, 45, 55, 65, 75,
};

static const uint8_t DEFAULT_CHROMA_QUANT[64] = {
    19, 19, 24, 47, 76, 99, 99, 99,
    19, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    76, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

/* K.5 AC luminance (mvs-huffman.js) */
static const uint8_t AC_BITS[16] = { 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125 };
static const uint8_t AC_VALUES[162] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
};

/* Coefficient buffer layout: Y[0..63], Cb[64..127], Cr[128..191], zigzag order */
enum { CB = 64, CR = 128, ENTRY_Y = 64, ENTRY_CR = 15, ENTRY_CB = 20 };

/* ---- Integer helpers with defined semantics ---- */

/* Arithmetic shift right (floor division by 2^n) without relying on
 * implementation-defined right shifts of negative values. */
static inline int64_t asr(int64_t v, unsigned n) {
    return v >= 0 ? (v >> n) : -(((-(v + 1)) >> n) + 1);
}

/* Two's complement truncations, as JavaScript typed array stores do */
static inline int16_t wrap16(int64_t v) {
    uint16_t u = (uint16_t)((uint64_t)v & 0xffffu);
    return u >= 0x8000u ? (int16_t)((int32_t)u - 0x10000) : (int16_t)u;
}
static inline int8_t wrap8(int64_t v) {
    uint8_t u = (uint8_t)((uint64_t)v & 0xffu);
    return u >= 0x80u ? (int8_t)((int32_t)u - 0x100) : (int8_t)u;
}
static inline int32_t wrap32(int64_t v) {
    uint32_t u = (uint32_t)((uint64_t)v & 0xffffffffu);
    return u >= 0x80000000u ? (int32_t)((int64_t)u - 0x100000000LL) : (int32_t)u;
}

static inline uint8_t clamp255(int32_t v) { return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v); }

/* libjpeg jdcolor.c with its tables folded in, for 0..255 samples. Adding 2^24
 * keeps each numerator positive, so the shift is a floor division without
 * signed shifts. Plain arithmetic lets the compiler vectorize a tile. */
static inline int32_t floor_shift16(int32_t v) { return (int32_t)((uint32_t)(v + (1 << 24)) >> 16) - 256; }
static inline uint8_t red(int32_t y, int32_t cr) { return clamp255(y + floor_shift16(91881 * (cr - 128) + 32768)); }
static inline uint8_t green(int32_t y, int32_t cb, int32_t cr) {
    return clamp255(y + floor_shift16(-22554 * (cb - 128) - 46802 * (cr - 128) + 32768));
}
static inline uint8_t blue(int32_t y, int32_t cb) { return clamp255(y + floor_shift16(116130 * (cb - 128) + 32768)); }

/* ---- Bitstream (mvs-bitstream.js). A read past the end sets a sticky
 * error and returns zeros, so every loop still ends; the caller checks the
 * error after each tile and returns it. ---- */

typedef struct {
    const uint8_t *data;
    size_t length, byte;
    unsigned bit;
    mvs_error *error;
} bitstream;

static unsigned read_bit(bitstream *b) {
    if (b->byte >= b->length) {
        if (!*b->error) *b->error = MVS_E_OVERRUN;
        return 0;
    }
    unsigned v = (b->data[b->byte] >> (7 - b->bit)) & 1u;
    if (++b->bit > 7) { b->bit = 0; b->byte++; }
    return v;
}

/* The next 64 bits, MSB first, when 8 bytes remain; the slow paths handle the tail. */
static inline bool peek64(const bitstream *b, uint64_t *out) {
    if (b->length - b->byte < 8 || b->byte > b->length) return false;
    uint64_t w;
    memcpy(&w, b->data + b->byte, 8);
    *out = (__builtin_bswap64(w) & (UINT64_MAX >> b->bit)) << b->bit;
    return true;
}

static inline void skip_bits(bitstream *b, unsigned n) {
    unsigned pos = b->bit + n;
    b->byte += pos >> 3;
    b->bit = pos & 7;
}

static uint32_t read_bits(bitstream *b, unsigned n) {
    uint64_t w;
    if (n && n <= 32 && peek64(b, &w)) {
        skip_bits(b, n);
        return (uint32_t)(w >> (64 - n));
    }
    uint32_t v = 0;
    for (unsigned i = 0; i < n; i++) v = (v << 1) | read_bit(b);
    return v;
}

static void fail(mvs_error *error, mvs_error e) { if (!*error) *error = e; }

/* ---- Rice codes (mvs-rice.js) ---- */

static uint32_t leading_ones(bitstream *b) {
    uint64_t w;
    if (peek64(b, &w)) {
        unsigned ones = ~w ? (unsigned)__builtin_clzll(~w) : 64;
        if (ones < 57) { skip_bits(b, ones + 1); return ones; }
    }
    uint32_t n = 0;
    while (read_bit(b) == 1) {
        if (++n > MVS_MAX_RICE_PREFIX) { fail(b->error, MVS_E_RICE); return 0; }
    }
    return n;
}

static int32_t signed_mag(bitstream *b, int32_t mag) { return read_bit(b) ? -mag : mag; }

static int32_t dc_rice(bitstream *b) {
    uint32_t n = leading_ones(b);
    if (n == 0) return read_bit(b) == 0 ? 0 : signed_mag(b, 1);
    if (n == 1) return signed_mag(b, 2 + (int32_t)read_bits(b, 1));
    if (n == 2) return signed_mag(b, 4 + (int32_t)read_bits(b, 2));
    return signed_mag(b, (int32_t)((n << 3) | read_bits(b, 3)) - 16);
}

static int32_t ac_rice_standard(bitstream *b) {
    uint32_t n = leading_ones(b);
    if (n == 0) return signed_mag(b, 2 + (int32_t)read_bits(b, 1));
    if (n == 1) return signed_mag(b, 4 + (int32_t)read_bits(b, 2));
    return signed_mag(b, (int32_t)((n << 3) | read_bits(b, 3)) - 8);
}

static int32_t ac_rice_near_dc(bitstream *b) {
    uint32_t n = leading_ones(b);
    if (n <= 3) return signed_mag(b, 2 + (int32_t)n * 4 + (int32_t)read_bits(b, 2));
    return signed_mag(b, 18 + ((int32_t)n - 4) * 8 + (int32_t)read_bits(b, 3));
}

static int32_t quant_step(unsigned pos, unsigned threshold) {
    if (pos <= 5) {
        if (threshold > 14) return 2;
        return pos < threshold ? 8 : 16;
    }
    if (threshold > 14 && pos < threshold) return 2;
    if (threshold > 14) return 8;
    return pos < threshold ? 8 : 16;
}

typedef struct { int32_t value; bool eob; unsigned skip; } ac_result;

static ac_result ac_coefficient(bitstream *b, unsigned pos, unsigned threshold) {
    ac_result r = { 0, false, 0 };
    if (read_bit(b)) {
        int32_t raw = pos <= 5 ? ac_rice_near_dc(b) : ac_rice_standard(b);
        r.value = raw * quant_step(pos, threshold);
        return r;
    }
    switch (read_bits(b, 2)) {
    case 0: break;
    case 1:
        if (read_bit(b) == 0) { r.eob = true; break; }
        {
            uint32_t ext = read_bits(b, 2);
            if (ext < 3) { r.skip = ext + 3; break; }
            unsigned run = 6;
            for (;;) {
                uint32_t chunk = read_bits(b, 3);
                run += chunk;
                if (chunk < 7) break;
                if (run + pos >= 64) break;
                if (*b->error) break;
            }
            r.skip = run;
        }
        break;
    case 2: r.value = quant_step(pos, threshold); break;
    case 3: r.value = -quant_step(pos, threshold); break;
    }
    return r;
}

/* ---- Huffman (mvs-huffman.js) ---- */

typedef struct { int32_t max_code[17], min_code[17], val_ptr[17]; } huffman_table;

static huffman_table build_table(void) {
    huffman_table t;
    memset(&t, 0, sizeof t);
    int32_t code = 0, index = 0;
    for (int len = 1; len <= 16; len++) {
        int32_t count = AC_BITS[len - 1];
        t.max_code[len] = -1;
        if (count == 0) { code <<= 1; continue; }
        t.min_code[len] = code;
        t.val_ptr[len] = index;
        index += count;
        t.max_code[len] = code + count - 1;
        code = (code + count) << 1;
    }
    return t;
}

static uint8_t huffman_symbol(bitstream *b, const huffman_table *t) {
    uint64_t w;
    if (peek64(b, &w)) {
        for (int len = 1; len <= 16; len++) {
            int32_t code = (int32_t)(w >> (64 - len));
            if (t->max_code[len] >= 0 && code <= t->max_code[len]) {
                int32_t index = t->val_ptr[len] + (code - t->min_code[len]);
                skip_bits(b, (unsigned)len);
                if (index >= 0 && index < (int32_t)sizeof AC_VALUES) return AC_VALUES[index];
                fail(b->error, MVS_E_HUFFMAN);
                return 0;
            }
        }
        skip_bits(b, 16);
        fail(b->error, MVS_E_HUFFMAN);
        return 0;
    }
    int32_t code = 0;
    for (int len = 1; len <= 16; len++) {
        code = (code << 1) | (int32_t)read_bit(b);
        if (t->max_code[len] >= 0 && code <= t->max_code[len]) {
            int32_t index = t->val_ptr[len] + (code - t->min_code[len]);
            if (index < 0 || index >= (int32_t)sizeof AC_VALUES) break;
            return AC_VALUES[index];
        }
    }
    fail(b->error, MVS_E_HUFFMAN);
    return 0; /* end of block, so the caller's loop ends */
}

static void huffman_ac(bitstream *b, const huffman_table *t, int16_t *coeffs, unsigned offset, unsigned limit) {
    unsigned k = 0;
    while (k < limit && !*b->error) {
        uint8_t symbol = huffman_symbol(b, t);
        unsigned run = symbol >> 4, value_bits = symbol & 0x0f;
        if (value_bits == 0) {
            if (run != 15) break;
            k += 16;
            continue;
        }
        k += run;
        int32_t raw = (int32_t)read_bits(b, value_bits);
        int32_t value = raw < (1 << (value_bits - 1)) ? raw - (1 << value_bits) + 1 : raw;
        coeffs[offset + (k + 1 < 63 ? k + 1 : 63)] = wrap16(value);
        k++;
    }
}

/* ---- Inverse DCT (mvs-idct.js, libjpeg jpeg_idct_islow) ---- */

enum { CONST_BITS = 13, PASS1_BITS = 2 };
#define FIX_0_298631336 2446
#define FIX_0_390180644 3196
#define FIX_0_541196100 4433
#define FIX_0_765366865 6270
#define FIX_0_899976223 7373
#define FIX_1_175875602 9633
#define FIX_1_501321110 12299
#define FIX_1_847759065 15137
#define FIX_1_961570560 16069
#define FIX_2_053119869 16819
#define FIX_2_562915447 20995
#define FIX_3_072711026 25172

/* libjpeg range limit: level shift by 128 and clamp, wrapping wildly
 * out-of-range values the way the 10-bit table does */
static uint8_t range_limit(int64_t v) {
    /* m < 128 gives m + 128, m < 512 gives 255, m < 896 gives 0, and the rest m - 896.
     * Rotating by 128 puts the two passthrough ranges first, without branches. */
    unsigned t = ((unsigned)((uint64_t)v & 0x3ffu) + 128u) & 0x3ffu;
    return t < 256 ? (uint8_t)t : (t < 640 ? 255 : 0);
}

/* range_limit(asr(v, n)) reads only bits n..n+9 of v, which a logical shift keeps. */
static inline uint8_t descale_limit(int64_t v, unsigned n) { return range_limit((int64_t)((uint64_t)v >> n)); }

/* wrap32(asr(v, n)) keeps bits n..n+31 of v, which a logical shift keeps too. */
static inline int32_t descale_wrap(int64_t v, unsigned n) { return wrap32((int64_t)((uint64_t)v >> n)); }

uint8_t mvs_idct_flat(int32_t dc) {
    return range_limit(asr((int64_t)dc * (1 << PASS1_BITS) + (1 << (PASS1_BITS + 2)), PASS1_BITS + 3));
}

void mvs_idct8x8(const int32_t block[64], uint8_t out[64]) {
    int32_t ws[64];
    for (int c = 0; c < 8; c++) {
        if (!block[c + 8] && !block[c + 16] && !block[c + 24] && !block[c + 32] &&
            !block[c + 40] && !block[c + 48] && !block[c + 56]) {
            int32_t dc = wrap32((int64_t)block[c] * (1 << PASS1_BITS));
            for (int r = 0; r < 64; r += 8) ws[c + r] = dc;
            continue;
        }
        int64_t z2 = block[c + 16], z3 = block[c + 48];
        int64_t z1 = (z2 + z3) * FIX_0_541196100;
        int64_t tmp2 = z1 - z3 * FIX_1_847759065;
        int64_t tmp3 = z1 + z2 * FIX_0_765366865;
        z2 = block[c];
        z3 = block[c + 32];
        int64_t tmp0 = (z2 + z3) * (1 << CONST_BITS);
        int64_t tmp1 = (z2 - z3) * (1 << CONST_BITS);
        int64_t tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
        tmp0 = block[c + 56]; tmp1 = block[c + 40]; tmp2 = block[c + 24]; tmp3 = block[c + 8];
        z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2;
        int64_t z4 = tmp1 + tmp3;
        int64_t z5 = (z3 + z4) * FIX_1_175875602;
        tmp0 *= FIX_0_298631336; tmp1 *= FIX_2_053119869; tmp2 *= FIX_3_072711026; tmp3 *= FIX_1_501321110;
        z1 *= -FIX_0_899976223; z2 *= -FIX_2_562915447;
        z3 = z3 * -FIX_1_961570560 + z5;
        z4 = z4 * -FIX_0_390180644 + z5;
        tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4;
        const unsigned shift = CONST_BITS - PASS1_BITS;
        const int64_t round = (int64_t)1 << (shift - 1);
        ws[c]      = descale_wrap(tmp10 + tmp3 + round, shift);
        ws[c + 56] = descale_wrap(tmp10 - tmp3 + round, shift);
        ws[c + 8]  = descale_wrap(tmp11 + tmp2 + round, shift);
        ws[c + 48] = descale_wrap(tmp11 - tmp2 + round, shift);
        ws[c + 16] = descale_wrap(tmp12 + tmp1 + round, shift);
        ws[c + 40] = descale_wrap(tmp12 - tmp1 + round, shift);
        ws[c + 24] = descale_wrap(tmp13 + tmp0 + round, shift);
        ws[c + 32] = descale_wrap(tmp13 - tmp0 + round, shift);
    }
    for (int r = 0; r < 64; r += 8) {
        if (!ws[r + 1] && !ws[r + 2] && !ws[r + 3] && !ws[r + 4] && !ws[r + 5] && !ws[r + 6] && !ws[r + 7]) {
            /* Every term but the DC is zero, so all eight outputs equal its rounded value. */
            const unsigned shift = CONST_BITS + PASS1_BITS + 3;
            memset(out + r, descale_limit((int64_t)ws[r] * (1 << CONST_BITS) + ((int64_t)1 << (shift - 1)), shift), 8);
            continue;
        }
        int64_t z2 = ws[r + 2], z3 = ws[r + 6];
        int64_t z1 = (z2 + z3) * FIX_0_541196100;
        int64_t tmp2 = z1 - z3 * FIX_1_847759065;
        int64_t tmp3 = z1 + z2 * FIX_0_765366865;
        int64_t tmp0 = ((int64_t)ws[r] + ws[r + 4]) * (1 << CONST_BITS);
        int64_t tmp1 = ((int64_t)ws[r] - ws[r + 4]) * (1 << CONST_BITS);
        int64_t tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2;
        tmp0 = ws[r + 7]; tmp1 = ws[r + 5]; tmp2 = ws[r + 3]; tmp3 = ws[r + 1];
        z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2;
        int64_t z4 = tmp1 + tmp3;
        int64_t z5 = (z3 + z4) * FIX_1_175875602;
        tmp0 *= FIX_0_298631336; tmp1 *= FIX_2_053119869; tmp2 *= FIX_3_072711026; tmp3 *= FIX_1_501321110;
        z1 *= -FIX_0_899976223; z2 *= -FIX_2_562915447;
        z3 = z3 * -FIX_1_961570560 + z5;
        z4 = z4 * -FIX_0_390180644 + z5;
        tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4;
        const unsigned shift = CONST_BITS + PASS1_BITS + 3;
        const int64_t round = (int64_t)1 << (shift - 1);
        out[r]     = descale_limit(tmp10 + tmp3 + round, shift);
        out[r + 7] = descale_limit(tmp10 - tmp3 + round, shift);
        out[r + 1] = descale_limit(tmp11 + tmp2 + round, shift);
        out[r + 6] = descale_limit(tmp11 - tmp2 + round, shift);
        out[r + 2] = descale_limit(tmp12 + tmp1 + round, shift);
        out[r + 5] = descale_limit(tmp12 - tmp1 + round, shift);
        out[r + 3] = descale_limit(tmp13 + tmp0 + round, shift);
        out[r + 4] = descale_limit(tmp13 - tmp0 + round, shift);
    }
}

/* ---- Decoder state ---- */

/* Per-screen-tile descriptor. Written by full updates only; the baseline
 * that partial updates are coded against. */
typedef struct {
    int8_t y[64];
    uint64_t initialized; /* One bit per pixel, independent of DCT baseline coefficients. */
    uint32_t frame_seq;
    int32_t ref_index;
    int32_t match_x, match_y;
    uint8_t threshold, cb_valid, cr_valid;
    int8_t cb_dc, cr_dc;
} tile_desc;

struct mvs_decoder {
    uint8_t luma_quant[64], chroma_quant[64]; /* in coefficient (zigzag) order */
    int16_t coeffs[192], dpcm[192];
    uint8_t solid[3], two_a[3], two_b[3];
    uint32_t tile[64];             /* pixels in the surface format of the current decode */
    unsigned red_shift, green_shift, blue_shift;
    uint32_t alpha;
    int8_t *cache;                 /* MVS_CACHE_SLOTS entries of 99 bytes; slot 0 unused */
    uint32_t cache_write, cache_last;
    uint64_t cache_count;
    tile_desc *desc;
    size_t tiles;
    uint32_t fb_width, fb_height, tiles_x;
    uint32_t frame_seq;
    huffman_table huffman;
    mvs_error error;               /* first failure of the current decode */
    mvs_stats *stats;
};

static bool checked_mul(size_t a, size_t b, size_t *out) { return !__builtin_mul_overflow(a, b, out); }
static bool checked_add(size_t a, size_t b, size_t *out) { return !__builtin_add_overflow(a, b, out); }

static size_t cache_bytes(void) { return (size_t)MVS_CACHE_SLOTS * MVS_CACHE_ENTRY_BYTES; }

size_t mvs_descriptor_bytes_for(uint32_t width, uint32_t height, size_t *tiles_out) {
    size_t tx = ((size_t)width + 7) / 8, ty = ((size_t)height + 7) / 8, tiles, bytes;
    if (!checked_mul(tx, ty, &tiles) || !checked_mul(tiles, sizeof(tile_desc), &bytes)) return 0;
    if (tiles_out) *tiles_out = tiles;
    return bytes;
}

/* Tables arrive in natural order; keep them in the order coefficients are coded. */
static void set_quant(mvs_decoder *d, const uint8_t luma[64], const uint8_t chroma[64]) {
    for (int i = 0; i < 64; i++) {
        d->luma_quant[i] = luma[ZIGZAG[i]];
        d->chroma_quant[i] = chroma[ZIGZAG[i]];
    }
}

mvs_decoder *mvs_create(void) {
    mvs_decoder *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->cache = calloc(MVS_CACHE_SLOTS, MVS_CACHE_ENTRY_BYTES);
    if (!d->cache) { free(d); return NULL; }
    set_quant(d, DEFAULT_LUMA_QUANT, DEFAULT_CHROMA_QUANT);
    d->huffman = build_table();
    return d;
}

void mvs_destroy(mvs_decoder *d) {
    if (!d) return;
    free(d->desc);
    free(d->cache);
    free(d);
}

void mvs_reset_picture(mvs_decoder *d) {
    if (!d) return;
    free(d->desc); d->desc=NULL;
    d->tiles=0; d->fb_width=d->fb_height=d->tiles_x=0;
}

size_t mvs_memory_bytes(const mvs_decoder *d, size_t *descriptor_bytes, size_t *cache_out, size_t *tiles) {
    size_t desc = 0, total;
    if (d && d->fb_width) desc = mvs_descriptor_bytes_for(d->fb_width, d->fb_height, tiles);
    else if (tiles) *tiles = 0;
    if (descriptor_bytes) *descriptor_bytes = desc;
    if (cache_out) *cache_out = cache_bytes();
    if (!checked_add(desc, cache_bytes(), &total) || !checked_add(total, sizeof(mvs_decoder), &total)) return 0;
    return total;
}

/* Reallocates the descriptors when the framebuffer size changes, as
 * _ensureScreenState does. The cache and quantization tables stay. */
static mvs_error ensure_screen(mvs_decoder *d, uint32_t width, uint32_t height) {
    if (width == d->fb_width && height == d->fb_height && d->desc) return MVS_OK;
    if (width == 0 || height == 0 || width > MVS_MAX_DIMENSION || height > MVS_MAX_DIMENSION) return MVS_E_SIZE;
    size_t tiles;
    if (!mvs_descriptor_bytes_for(width, height, &tiles)) return MVS_E_SIZE;
    tile_desc *desc = calloc(tiles, sizeof *desc);
    if (!desc) return MVS_E_ALLOCATION;
    for (size_t i = 0; i < tiles; i++) desc[i].ref_index = -1;
    free(d->desc);
    d->desc = desc;
    d->tiles = tiles;
    d->fb_width = width;
    d->fb_height = height;
    d->tiles_x = (width + 7) / 8;
    return MVS_OK;
}

/* Coverage follows actual pixels, including clipped tiles and unaligned Raw rectangles.
 * Descriptor allocation resets coverage whenever geometry changes. */
static bool coverage(mvs_decoder *d, uint32_t x, uint32_t y, uint32_t w, uint32_t h, bool mark) {
    if (!d || !d->desc || !w || !h || (uint64_t)x+w>d->fb_width || (uint64_t)y+h>d->fb_height) return false;
    for (uint32_t ty=y/8; ty<=(y+h-1)/8; ty++) {
        for (uint32_t tx=x/8; tx<=(x+w-1)/8; tx++) {
            uint32_t left=x>tx*8?x-tx*8:0, right=x+w<tx*8+8?x+w-tx*8:8;
            uint32_t top=y>ty*8?y-ty*8:0, bottom=y+h<ty*8+8?y+h-ty*8:8;
            uint64_t mask=0, row=((UINT64_C(1)<<(right-left))-1)<<left;
            for (uint32_t r=top; r<bottom; r++) mask|=row<<(r*8);
            tile_desc *t=&d->desc[(size_t)ty*d->tiles_x+tx];
            if (mark) {
                t->initialized|=mask;
            } else if ((t->initialized&mask)!=mask) return false;
        }
    }
    return true;
}

int mvs_region_initialized(const mvs_decoder *d, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    return coverage((mvs_decoder *)d,x,y,w,h,false);
}

mvs_error mvs_mark_raw(mvs_decoder *d, uint32_t width, uint32_t height, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (!d) return MVS_E_ARGUMENT;
    mvs_error e=ensure_screen(d,width,height);
    if (e) return e;
    return coverage(d,x,y,w,h,true)?MVS_OK:MVS_E_RECT;
}

/* ---- Framebuffer access ---- */

static void put_tile(mvs_decoder *d, const mvs_surface *s, uint32_t tx, uint32_t ty, uint32_t tw, uint32_t th,
                     mvs_written_fn written, void *context) {
    uint8_t *dst = s->pixels + (size_t)ty * s->stride + (size_t)tx * 4;
    if (tw == 8)
        for (uint32_t row = 0; row < th; row++) memcpy(dst + row * s->stride, d->tile + row * 8, 32);
    else
        for (uint32_t row = 0; row < th; row++) memcpy(dst + row * s->stride, d->tile + row * 8, (size_t)tw * 4);
    coverage(d,tx,ty,tw,th,true);
    if (written) written(context, tx, ty, tw, th);
}

/* Copies a tile within the framebuffer. A source outside the framebuffer
 * leaves the destination as it is, as _copyTile does. */
static void copy_tile(mvs_decoder *d, const mvs_surface *s, int64_t sx, int64_t sy,
                      uint32_t dx, uint32_t dy, uint32_t tw, uint32_t th,
                      mvs_written_fn written, void *context) {
    if (sx < 0 || sy < 0 || sx >= d->fb_width || sy >= d->fb_height) {
        if (d->stats) d->stats->copy_skipped++;
        return;
    }
    uint32_t cols = tw < d->fb_width - (uint32_t)sx ? tw : d->fb_width - (uint32_t)sx;
    uint32_t rows = th < d->fb_height - (uint32_t)sy ? th : d->fb_height - (uint32_t)sy;
    if (!coverage(d,(uint32_t)sx,(uint32_t)sy,cols,rows,false)) { fail(&d->error,MVS_E_BASELINE); return; }
    for (uint32_t row = 0; row < rows; row++) {
        memmove(s->pixels + (size_t)(dy + row) * s->stride + (size_t)dx * 4,
                s->pixels + (size_t)((uint32_t)sy + row) * s->stride + (size_t)sx * 4, (size_t)cols * 4);
    }
    coverage(d,dx,dy,cols,rows,true);
    if (written && cols && rows) written(context, dx, dy, cols, rows);
}

/* ---- Dequantize, transform, colour convert (into d->tile) ---- */

static inline uint32_t pack_rgb(const mvs_decoder *d, const uint8_t rgb[3]) {
    return ((uint32_t)rgb[0] << d->red_shift) | ((uint32_t)rgb[1] << d->green_shift) |
           ((uint32_t)rgb[2] << d->blue_shift) | d->alpha;
}

static int transform_plane(mvs_decoder *d, unsigned plane, const uint8_t quant[64], uint8_t out[64]) {
    const int16_t *c = d->coeffs + plane;
    int32_t ac = 0;
    for (int i = 1; i < 64; i++) ac |= c[i];
    int32_t dc = c[0] * quant[0];
    if (ac == 0) return mvs_idct_flat(dc);
    int32_t dq[64];
    bool wide = false;
    for (int i = 0; i < 64; i++) {
        int32_t v = c[i] * quant[i];
        wide |= v > 4096 || v < -4096;
        dq[ZIGZAG[i]] = v;
    }
    if (wide && d->stats) d->stats->wide_idct++;
    mvs_idct8x8(dq, out);
    return -1;
}

static void render(mvs_decoder *d, const uint8_t ys[64], const uint8_t cbs[64], const uint8_t crs[64]) {
    /* Locals, because the stores to d->tile could alias the decoder's fields. */
    const unsigned rs = d->red_shift, gs = d->green_shift, bs = d->blue_shift;
    const uint32_t alpha = d->alpha;
    uint32_t *tile = d->tile;
    for (int i = 0; i < 64; i++)
        tile[i] = ((uint32_t)red(ys[i], crs[i]) << rs) | ((uint32_t)green(ys[i], cbs[i], crs[i]) << gs) |
                  ((uint32_t)blue(ys[i], cbs[i]) << bs) | alpha;
}

static void dequant_and_render(mvs_decoder *d) {
    uint8_t ys[64], cbs[64], crs[64];
    int y_flat = transform_plane(d, 0, d->luma_quant, ys);
    if (y_flat >= 0) memset(ys, y_flat, 64);
    int cb_flat = transform_plane(d, CB, d->chroma_quant, cbs);
    int cr_flat = transform_plane(d, CR, d->chroma_quant, crs);
    if (cb_flat >= 0) memset(cbs, cb_flat, 64);
    if (cr_flat >= 0) memset(crs, cr_flat, 64);
    render(d, ys, cbs, crs);
}

static void fill_tile(mvs_decoder *d, const uint8_t rgb[3]) {
    const uint32_t px = pack_rgb(d, rgb);
    for (int i = 0; i < 64; i++) d->tile[i] = px;
}

/* ---- Cache ---- */

static bool load_cache(mvs_decoder *d, uint32_t idx) {
    if (idx == 0 || idx >= MVS_CACHE_SLOTS || idx > d->cache_count) {
        fail(&d->error, MVS_E_CACHE_SLOT);
        return false;
    }
    const int8_t *e = d->cache + (size_t)idx * MVS_CACHE_ENTRY_BYTES;
    memset(d->coeffs, 0, sizeof d->coeffs);
    for (int i = 0; i < ENTRY_Y; i++) d->coeffs[i] = e[i];
    for (int i = 0; i < ENTRY_CR; i++) d->coeffs[CR + i] = e[ENTRY_Y + i];
    for (int i = 0; i < ENTRY_CB; i++) d->coeffs[CB + i] = e[ENTRY_Y + ENTRY_CR + i];
    dequant_and_render(d);
    d->cache_last = idx;
    return true;
}

/* ---- Full update tiles ---- */

static void read_ycbcr20(bitstream *b, uint8_t rgb[3]) {
    int32_t y = (int32_t)read_bits(b, 8);
    unsigned cb = read_bits(b, 6) << 2, cr = read_bits(b, 6) << 2;
    rgb[0] = red(y, (int32_t)cr);
    rgb[1] = green(y, (int32_t)cb, (int32_t)cr);
    rgb[2] = blue(y, (int32_t)cb);
}

static void two_color_bitmap(mvs_decoder *d, bitstream *b, const uint8_t a[3], const uint8_t c[3]) {
    const uint32_t pa = pack_rgb(d, a), pc = pack_rgb(d, c);
    uint32_t selector = read_bits(b, 8);
    for (int row = 0; row < 8; row++) {
        uint32_t bits = ((selector >> (7 - row)) & 1) ? 0xff : read_bits(b, 8);
        for (int col = 0; col < 8; col++) d->tile[row * 8 + col] = ((bits >> (7 - col)) & 1) ? pa : pc;
    }
}

static void black_white(mvs_decoder *d, bitstream *b) {
    static const uint8_t white[3] = { 255, 255, 255 }, black[3] = { 0, 0, 0 };
    two_color_bitmap(d, b, white, black);
}

static void solid_or_two_color(mvs_decoder *d, bitstream *b) {
    unsigned two = read_bit(b), reuse = read_bit(b);
    if (!two) {
        if (!reuse) read_ycbcr20(b, d->solid);
        fill_tile(d, d->solid);
    } else {
        if (!reuse) { read_ycbcr20(b, d->two_a); read_ycbcr20(b, d->two_b); }
        two_color_bitmap(d, b, d->two_a, d->two_b);
    }
}

static void full_dct(mvs_decoder *d, bitstream *b, unsigned t1, unsigned t2, size_t screen, int64_t prev) {
    int16_t *c = d->coeffs;
    const int16_t *state = d->dpcm;
    memset(d->coeffs, 0, sizeof d->coeffs);
    if (read_bit(b)) {
        if (prev < 0) { fail(&d->error, MVS_E_REPEAT); return; }
        memcpy(c, state, 64 * sizeof *c);
        c[CB] = state[CB];
        c[CR] = state[CR];
        d->desc[screen] = d->desc[(size_t)prev];
    } else {
        unsigned dc_mode = read_bit(b);
        unsigned threshold = read_bit(b) ? t2 : t1;
        if (dc_mode == 0) {
            int32_t cb_rice = dc_rice(b);
            c[CB] = wrap16(((int64_t)state[CB] / 2 - cb_rice) * 2);
            int32_t cr_rice = dc_rice(b);
            c[CR] = wrap16(((int64_t)state[CR] / 2 - cr_rice) * 2);
        } else {
            c[CB] = state[CB];
            c[CR] = state[CR];
        }
        c[0] = wrap16((int64_t)state[0] - dc_rice(b));
        unsigned pos = 1;
        while (pos < 64 && !d->error) {
            ac_result r = ac_coefficient(b, pos, threshold);
            if (r.eob) break;
            if (r.skip > 0) pos += r.skip;
            else c[pos++] = wrap16(r.value);
        }
        tile_desc *t = &d->desc[screen];
        t->threshold = (uint8_t)threshold;
        for (int i = 0; i < 64; i++) t->y[i] = wrap8(c[i]);
        t->cb_valid = 1;
        t->cb_dc = wrap8(c[CB]);
        t->cr_valid = 1;
        t->cr_dc = wrap8(c[CR]);
    }
    memcpy(d->dpcm, c, sizeof d->dpcm);
    dequant_and_render(d);
}

static void tile_geometry(uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t tiles_x, size_t index,
                          uint32_t *tx, uint32_t *ty, uint32_t *tw, uint32_t *th) {
    uint32_t col = (uint32_t)(index % tiles_x), row = (uint32_t)(index / tiles_x);
    *tx = x + col * 8;
    *ty = y + row * 8;
    *tw = x + w - *tx < 8 ? x + w - *tx : 8;
    *th = y + h - *ty < 8 ? y + h - *ty : 8;
}

static void full_update(mvs_decoder *d, const mvs_surface *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                        const uint8_t *data, size_t length, mvs_written_fn written, void *context) {
    if (length < 6) { fail(&d->error, MVS_E_SHORT); return; }
    unsigned t1 = data[1], t2 = data[2];
    uint32_t tiles_x = (w + 7) / 8, tiles_y = (h + 7) / 8;
    size_t total = (size_t)tiles_x * tiles_y;
    size_t body_offset = ((size_t)data[3] << 16) | ((size_t)data[4] << 8) | data[5];
    if (body_offset < 6 || body_offset > length) { fail(&d->error, MVS_E_BODY_OFFSET); return; }
    bitstream header = { data + 6, body_offset - 6, 0, 0, &d->error };
    bitstream body = { data + body_offset, length - body_offset, 0, 0, &d->error };

    read_bit(&header);
    d->frame_seq++;
    memset(d->dpcm, 0, sizeof d->dpcm);
    memset(d->solid, 0, 3);
    memset(d->two_a, 255, 3);
    d->two_b[0] = 181; d->two_b[1] = 213; d->two_b[2] = 254;

    int64_t prev_dct = -1;
    uint32_t prev_x = x, prev_y = y;
    size_t index = 0;
    while (index < total && !d->error) {
        unsigned type = read_bits(&header, 3);
        uint64_t count = 1;
        if (read_bit(&header)) {
            uint32_t v4 = read_bits(&header, 4);
            if (v4 < 15) count = v4 + 2;
            else {
                uint32_t b1 = read_bits(&header, 8), varint;
                if (!(b1 & 0x80)) varint = b1;
                else {
                    uint32_t b2 = read_bits(&header, 8);
                    if (!(b2 & 0x80)) varint = (b2 << 7) | (b1 & 0x7f);
                    else varint = (read_bits(&header, 8) << 14) | ((b2 & 0x7f) << 7) | (b1 & 0x7f);
                }
                count = (uint64_t)varint + 17;
            }
        }
        for (; count > 0 && index < total && !d->error; count--, index++) {
            uint32_t tx, ty, tw, th;
            tile_geometry(x, y, w, h, tiles_x, index, &tx, &ty, &tw, &th);
            size_t screen = (size_t)(ty >> 3) * d->tiles_x + (tx >> 3);
            tile_desc *t = &d->desc[screen];
            t->frame_seq = d->frame_seq;
            t->ref_index = -1;
            t->cb_valid = t->cr_valid = 0;
            bool rendered = true;
            if (d->stats) d->stats->full_tiles[type]++;
            switch (type) {
            case 0: { static const uint8_t white[3] = { 255, 255, 255 }; fill_tile(d, white); break; }
            case 1:
                t->ref_index = wrap32((int64_t)screen - 1);
                t->match_x = (int32_t)prev_x;
                t->match_y = (int32_t)prev_y;
                copy_tile(d, s, prev_x, prev_y, tx, ty, tw, th, written, context);
                rendered = false;
                break;
            case 2:
                t->ref_index = wrap32((int64_t)screen - d->tiles_x);
                t->match_x = (int32_t)tx;
                t->match_y = (int32_t)ty - 8;
                copy_tile(d, s, tx, (int64_t)ty - 8, tx, ty, tw, th, written, context);
                rendered = false;
                break;
            case 3: black_white(d, &body); break;
            case 4: solid_or_two_color(d, &body); break;
            case 5: full_dct(d, &body, t1, t2, screen, prev_dct); prev_dct = (int64_t)screen; break;
            case 6: { uint32_t idx = read_bits(&body, 16); rendered = !d->error && load_cache(d, idx); break; }
            case 7: rendered = load_cache(d, (d->cache_last + 1) & 0xffff); break;
            }
            if (d->error) return;
            if (rendered) put_tile(d, s, tx, ty, tw, th, written, context);
            prev_x = tx;
            prev_y = ty;
        }
    }
    if (d->error) return;
    if (read_bits(&header, 8) != 0x6d) { fail(&d->error, MVS_E_HEADER_MARKER); return; }
    if (read_bits(&body, 8) != 0x6d) fail(&d->error, MVS_E_BODY_MARKER);
}

/* ---- Partial update ---- */

static int8_t chroma_dc_delta(bitstream *b, int8_t baseline) {
    unsigned bit = read_bit(b);
    if (baseline != 0) return wrap8(baseline >= 0 ? baseline + (int)bit : baseline - (int)bit);
    if (bit) return read_bit(b) ? -1 : 1;
    return 0;
}

static void partial_dct(mvs_decoder *d, bitstream *b, size_t screen, unsigned cr_limit, unsigned cb_limit) {
    const tile_desc *t = &d->desc[screen];
    if (!t->cr_valid || !t->cb_valid) { fail(&d->error, MVS_E_BASELINE); return; }
    int16_t *c = d->coeffs;
    int8_t entry[MVS_CACHE_ENTRY_BYTES];
    memset(d->coeffs, 0, sizeof d->coeffs);
    memset(entry, 0, sizeof entry);
    unsigned threshold = t->threshold;
    c[0] = t->y[0];
    entry[0] = t->y[0];

    unsigned ac_count = read_bits(b, 6);
    unsigned end = ac_count + 1;
    unsigned desc_pos = 1, entry_pos = 1;
    unsigned phase1_end = end < threshold ? end : threshold;
    for (unsigned pos = 1; pos < phase1_end; pos++) {
        int32_t prev = desc_pos < 64 ? t->y[desc_pos] : 0;
        desc_pos++;
        int8_t value = 0;
        if (threshold < 15) {
            if (prev == 0) value = wrap8(dc_rice(b));
            else { int32_t delta = (int32_t)read_bits(b, 3); value = wrap8(prev >= 0 ? prev + delta : prev - delta); }
        } else {
            if (prev == 0) { if (read_bit(b)) value = read_bit(b) ? -1 : 1; }
            else { int32_t delta = (int32_t)read_bit(b); value = wrap8(prev >= 0 ? prev + delta : prev - delta); }
        }
        c[pos] = value;
        entry[entry_pos++] = value;
    }
    if (ac_count >= threshold) {
        unsigned delta_bits = threshold < 15 ? 4 : 3;
        for (unsigned pos = threshold; pos < end; pos++) {
            int32_t prev = desc_pos < 64 ? t->y[desc_pos] : 0;
            desc_pos++;
            int8_t value;
            if (prev == 0) value = wrap8(dc_rice(b));
            else { int32_t delta = (int32_t)read_bits(b, delta_bits); value = wrap8(prev >= 0 ? prev + delta : prev - delta); }
            c[pos] = value;
            entry[entry_pos++] = value;
        }
    }

    c[CR] = chroma_dc_delta(b, t->cr_dc);
    huffman_ac(b, &d->huffman, c, CR, cr_limit);
    for (int i = 0; i < ENTRY_CR; i++) entry[ENTRY_Y + i] = wrap8(c[CR + i]);
    c[CB] = chroma_dc_delta(b, t->cb_dc);
    huffman_ac(b, &d->huffman, c, CB, cb_limit);
    for (int i = 0; i < ENTRY_CB; i++) entry[ENTRY_Y + ENTRY_CR + i] = wrap8(c[CB + i]);
    if (d->error) return;

    dequant_and_render(d);
    if (++d->cache_write == MVS_CACHE_SLOTS) d->cache_write = 1;
    d->cache_count++;
    memcpy(d->cache + (size_t)d->cache_write * MVS_CACHE_ENTRY_BYTES, entry, sizeof entry);
}

static void partial_update(mvs_decoder *d, const mvs_surface *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                           const uint8_t *data, size_t length, mvs_written_fn written, void *context) {
    if (length < 3) { fail(&d->error, MVS_E_SHORT); return; }
    unsigned cr_limit = data[1] < 64 ? data[1] : 64, cb_limit = data[2] < 64 ? data[2] : 64;
    uint32_t tiles_x = (w + 7) / 8, tiles_y = (h + 7) / 8;
    size_t total = (size_t)tiles_x * tiles_y;
    bitstream b = { data + 3, length - 3, 0, 0, &d->error };
    for (size_t index = 0; index < total && !d->error; index++) {
        uint32_t tx, ty, tw, th;
        tile_geometry(x, y, w, h, tiles_x, index, &tx, &ty, &tw, &th);
        size_t screen = (size_t)(ty >> 3) * d->tiles_x + (tx >> 3);
        unsigned code = read_bits(&b, 2);
        if (d->stats) d->stats->partial_tiles[code]++;
        switch (code) {
        case 0: break;
        case 1:
            partial_dct(d, &b, screen, cr_limit, cb_limit);
            if (!d->error) put_tile(d, s, tx, ty, tw, th, written, context);
            break;
        case 2: {
            const tile_desc *t = &d->desc[screen];
            int64_t ref = t->ref_index;
            if (ref >= 0 && (size_t)ref < d->tiles && t->frame_seq == d->desc[ref].frame_seq)
                copy_tile(d, s, t->match_x, t->match_y, tx, ty, tw, th, written, context);
            else if (d->stats) d->stats->copy_skipped++;
            break;
        }
        case 3: {
            uint32_t idx = read_bit(&b) ? (d->cache_last + 1) & 0xffff : read_bits(&b, 16);
            if (!d->error && load_cache(d, idx)) put_tile(d, s, tx, ty, tw, th, written, context);
            break;
        }
        }
    }
    if (d->error) return;
    uint32_t m = read_bits(&b, 8), v = read_bits(&b, 8), sx = read_bits(&b, 8);
    if (!d->error && (m != 0x6d || v != 0x76 || sx != 0x73)) fail(&d->error, MVS_E_PARTIAL_MARKER);
}

/* ---- Entry point ---- */

static bool valid_shifts(const mvs_surface *s) {
    unsigned r = s->red_shift, g = s->green_shift, b = s->blue_shift;
    return r <= 24 && g <= 24 && b <= 24 && r % 8 == 0 && g % 8 == 0 && b % 8 == 0 && r != g && g != b && r != b;
}

static mvs_error decode_rect(mvs_decoder *d, const mvs_surface *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                             const uint8_t *payload, size_t length, mvs_written_fn written, void *context) {
    mvs_error e = ensure_screen(d, s->width, s->height);
    if (e) return e;
    if (length == 0) return MVS_E_EMPTY;
    uint8_t type = payload[0];
    if (type > 0x02) return MVS_E_UPDATE_TYPE;
    if (d->stats) d->stats->kind = (mvs_kind)type;
    if (type == 0x02) {
        if (length != 129) return MVS_E_QUANT_LENGTH;
        set_quant(d, payload + 1, payload + 65);
        return MVS_OK;
    }
    if ((uint64_t)x + w > s->width || (uint64_t)y + h > s->height) return MVS_E_RECT;
    if (type == 0x00) full_update(d, s, x, y, w, h, payload, length, written, context);
    else {
        if (!coverage(d,x,y,w,h,false)) return MVS_E_BASELINE;
        partial_update(d, s, x, y, w, h, payload, length, written, context);
    }
    return d->error;
}

mvs_error mvs_decode(mvs_decoder *d, const mvs_surface *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                     const uint8_t *payload, size_t length, mvs_written_fn written, void *context, mvs_stats *stats) {
    if (!d || !s || !s->pixels || (!payload && length) || !valid_shifts(s)) return MVS_E_ARGUMENT;
    size_t row_bytes;
    if (!checked_mul(s->width, 4, &row_bytes) || s->stride < row_bytes) return MVS_E_ARGUMENT;
    if (stats) memset(stats, 0, sizeof *stats);
    d->stats = stats;
    d->error = MVS_OK;
    d->red_shift = s->red_shift;
    d->green_shift = s->green_shift;
    d->blue_shift = s->blue_shift;
    uint32_t alpha_shift = 48u - s->red_shift - s->green_shift - s->blue_shift;
    d->alpha = alpha_shift < 32 ? 0xffu << alpha_shift : 0;
    mvs_error e = decode_rect(d, s, x, y, w, h, payload, length, written, context);
    d->stats = NULL;
    return e;
}
