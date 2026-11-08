/*
 * Owned MVS decoder tests, run under ASan and UBSan.
 *
 * The bitstream vectors and their expected pixels are ported from
 * noVNC-ARD ard/tests/test.mvs.js (MPL-2.0), commit
 * d699293635083c9e0c30c8f9480993865653772a. The malformed-input, cache
 * bound, resize and fuzz cases are new.
 */
#include "mvs.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

typedef struct { uint8_t bytes[512]; size_t length; } buffer;

static void push(buffer *b, uint8_t v) { if (b->length < sizeof b->bytes) b->bytes[b->length++] = v; }

/* Join bit strings (spaces ignored) into bytes, zero padded. NULL ends the list. */
static buffer bits(const char *first, ...) {
    buffer out = { {0}, 0 };
    size_t n = 0;
    __builtin_va_list ap;
    __builtin_va_start(ap, first);
    for (const char *part = first; part; part = __builtin_va_arg(ap, const char *)) {
        for (const char *c = part; *c; c++) {
            if (*c != '0' && *c != '1') continue;
            if (n % 8 == 0) push(&out, 0);
            if (*c == '1') out.bytes[n / 8] |= (uint8_t)(0x80 >> (n % 8));
            n++;
        }
    }
    __builtin_va_end(ap);
    return out;
}

static char marker_text[3][64];
static const char *marker(const char *text, int slot) {
    char *o = marker_text[slot];
    for (const char *c = text; *c; c++) for (int i = 7; i >= 0; i--) *o++ = ((*c >> i) & 1) ? '1' : '0';
    *o = 0;
    return marker_text[slot];
}

static buffer full_update(uint8_t t1, uint8_t t2, buffer header, buffer body) {
    buffer out = { {0}, 0 };
    size_t offset = 6 + header.length;
    push(&out, 0); push(&out, t1); push(&out, t2);
    push(&out, (uint8_t)(offset >> 16)); push(&out, (uint8_t)(offset >> 8)); push(&out, (uint8_t)offset);
    for (size_t i = 0; i < header.length; i++) push(&out, header.bytes[i]);
    for (size_t i = 0; i < body.length; i++) push(&out, body.bytes[i]);
    return out;
}

static buffer partial_update(uint8_t cr, uint8_t cb, buffer body) {
    buffer out = { {0}, 0 };
    push(&out, 1); push(&out, cr); push(&out, cb);
    for (size_t i = 0; i < body.length; i++) push(&out, body.bytes[i]);
    return out;
}

#define EOB "1010"

static buffer FULL, FULL_AC, PARTIAL_CR_UP, PARTIAL_UNCHANGED, PARTIAL_CACHE_1, PARTIAL_CACHE_NEXT, PARTIAL_AC_1, PARTIAL_AC_0;

static void build_vectors(void) {
    FULL = full_update(15, 25,
        bits("0", "101 1 0000", marker("m", 0), NULL),
        bits("0 0 0", "00", "00", "1110 010 1", "0 01 0", "1", marker("m", 1), NULL));
    FULL_AC = full_update(15, 25,
        bits("0", "101 1 0000", marker("m", 0), NULL),
        bits("0 0 0", "00", "00", "1110 010 1", "0 10", "0 01 0", "1", marker("m", 1), NULL));
    PARTIAL_AC_1 = partial_update(14, 19, bits("01", "000001", "1", "0", EOB, "0", EOB, "00", marker("mvs", 2), NULL));
    PARTIAL_AC_0 = partial_update(14, 19, bits("01", "000001", "0", "0", EOB, "0", EOB, "00", marker("mvs", 2), NULL));
    PARTIAL_CR_UP = partial_update(14, 19, bits("01", "000000", "1 0", EOB, "0", EOB, "00", marker("mvs", 2), NULL));
    PARTIAL_UNCHANGED = partial_update(14, 19, bits("01", "000000", "0", EOB, "0", EOB, "00", marker("mvs", 2), NULL));
    PARTIAL_CACHE_1 = partial_update(14, 19, bits("00", "11 0 0000000000000001", marker("mvs", 2), NULL));
    PARTIAL_CACHE_NEXT = partial_update(14, 19, bits("00", "11 1", marker("mvs", 2), NULL));
}

/* A screen in the probe's pixel format: red 16, green 8, blue 0 */
typedef struct { uint8_t *pixels; mvs_surface surface; mvs_decoder *decoder; } screen;

static screen screen_new(uint32_t w, uint32_t h) {
    screen s;
    s.pixels = calloc((size_t)w * h, 4);
    s.surface = (mvs_surface){ s.pixels, w, h, (size_t)w * 4, 16, 8, 0 };
    s.decoder = mvs_create();
    return s;
}
static void screen_free(screen *s) { mvs_destroy(s->decoder); free(s->pixels); }

static mvs_error decode_at(screen *s, const buffer *p, uint32_t x, uint32_t y) {
    return mvs_decode(s->decoder, &s->surface, x, y, 16, 8, p->bytes, p->length, NULL, NULL, NULL);
}
static mvs_error decode(screen *s, const buffer *p) { return decode_at(s, p, 0, 0); }

static bool rgb_is(const screen *s, uint32_t x, uint32_t y, int r, int g, int b) {
    uint32_t px;
    memcpy(&px, s->pixels + ((size_t)y * s->surface.width + x) * 4, 4);
    return (int)((px >> 16) & 0xff) == r && (int)((px >> 8) & 0xff) == g && (int)(px & 0xff) == b;
}
#define GRAY 148, 148, 148
#define REDDISH 151, 147, 148
#define BLACK 0, 0, 0

static void tile_pixels(const screen *s, int tile, uint32_t out[64]) {
    for (int row = 0; row < 8; row++) memcpy(out + row * 8, s->pixels + ((size_t)row * 16 + (size_t)tile * 8) * 4, 32);
}

static void test_reference_vectors(void) {
    { screen s = screen_new(16, 8);
      CHECK(decode(&s, &FULL) == MVS_OK);
      CHECK(rgb_is(&s, 0, 0, GRAY)); CHECK(rgb_is(&s, 8, 0, GRAY)); CHECK(rgb_is(&s, 15, 7, GRAY));
      screen_free(&s); }
    { screen s = screen_new(16, 8);
      uint8_t tables[129]; memset(tables, 8, sizeof tables); tables[0] = 2;
      CHECK(mvs_decode(s.decoder, &s.surface, 0, 0, 0, 0, tables, sizeof tables, NULL, NULL, NULL) == MVS_OK);
      CHECK(decode(&s, &FULL) == MVS_OK);
      CHECK(rgb_is(&s, 0, 0, 138, 138, 138));
      screen_free(&s); }
    { screen s = screen_new(16, 8);
      CHECK(decode(&s, &FULL) == MVS_OK); CHECK(decode(&s, &PARTIAL_CR_UP) == MVS_OK);
      CHECK(rgb_is(&s, 0, 0, REDDISH)); CHECK(rgb_is(&s, 8, 0, GRAY));
      CHECK(decode(&s, &PARTIAL_UNCHANGED) == MVS_OK);
      CHECK(rgb_is(&s, 0, 0, GRAY));
      CHECK(decode(&s, &PARTIAL_CACHE_1) == MVS_OK);
      CHECK(rgb_is(&s, 8, 0, REDDISH));
      CHECK(decode(&s, &PARTIAL_CACHE_NEXT) == MVS_OK);
      CHECK(rgb_is(&s, 8, 0, GRAY));
      screen_free(&s); }
    { uint32_t full[64], stepped[64], back[64];
      screen a = screen_new(16, 8), b = screen_new(16, 8), c = screen_new(16, 8);
      CHECK(decode(&a, &FULL_AC) == MVS_OK); tile_pixels(&a, 0, full);
      CHECK(decode(&b, &FULL_AC) == MVS_OK); CHECK(decode(&b, &PARTIAL_AC_1) == MVS_OK); tile_pixels(&b, 0, stepped);
      CHECK(decode(&c, &FULL_AC) == MVS_OK); CHECK(decode(&c, &PARTIAL_AC_1) == MVS_OK);
      CHECK(decode(&c, &PARTIAL_AC_0) == MVS_OK); tile_pixels(&c, 0, back);
      CHECK(memcmp(full, stepped, sizeof full) != 0);
      CHECK(memcmp(full, back, sizeof full) == 0);
      screen_free(&a); screen_free(&b); screen_free(&c); }
    { screen s = screen_new(16, 8);
      CHECK(decode(&s, &FULL) == MVS_OK);
      CHECK(decode(&s, &PARTIAL_CACHE_1) == MVS_E_CACHE_SLOT);
      screen_free(&s); }
    /* A 16x8 display at 16,3 in a 32x16 framebuffer */
    { screen s = screen_new(32, 16);
      CHECK(decode_at(&s, &FULL, 16, 3) == MVS_OK);
      CHECK(rgb_is(&s, 16, 3, GRAY)); CHECK(rgb_is(&s, 31, 10, GRAY));
      CHECK(rgb_is(&s, 16, 2, BLACK)); CHECK(rgb_is(&s, 16, 11, BLACK)); CHECK(rgb_is(&s, 15, 3, BLACK));
      CHECK(decode_at(&s, &PARTIAL_CR_UP, 16, 3) == MVS_OK);
      CHECK(decode_at(&s, &PARTIAL_UNCHANGED, 16, 3) == MVS_OK);
      CHECK(decode_at(&s, &PARTIAL_CACHE_1, 16, 3) == MVS_OK);
      CHECK(rgb_is(&s, 16, 3, GRAY)); CHECK(rgb_is(&s, 24, 3, REDDISH));
      screen_free(&s); }
    { screen s = screen_new(32, 16);
      CHECK(decode_at(&s, &FULL, 24, 3) == MVS_E_RECT);
      CHECK(rgb_is(&s, 24, 3, BLACK));
      screen_free(&s); }
}

static void test_idct_flat(void) {
    int32_t block[64] = {0};
    uint8_t out[64];
    int mismatches = 0;
    for (int32_t dc = -40000; dc <= 40000; dc++) {
        block[0] = dc;
        mvs_idct8x8(block, out);
        uint8_t flat = mvs_idct_flat(dc);
        for (int i = 0; i < 64; i++) if (out[i] != flat) { mismatches++; break; }
    }
    CHECK(mismatches == 0);
}

static void test_malformed(void) {
    /* Every proper prefix of every vector fails, and none crashes */
    const buffer *all[] = { &FULL, &FULL_AC, &PARTIAL_CR_UP, &PARTIAL_UNCHANGED, &PARTIAL_AC_1 };
    for (size_t v = 0; v < sizeof all / sizeof *all; v++) {
        for (size_t len = 0; len < all[v]->length; len++) {
            screen s = screen_new(16, 8);
            if (all[v]->bytes[0] == 1) CHECK(decode(&s, &FULL) == MVS_OK);
            buffer cut = *all[v];
            cut.length = len;
            CHECK(decode(&s, &cut) != MVS_OK);
            screen_free(&s);
        }
    }
    screen s = screen_new(16, 8);
    buffer empty = { {0}, 0 };
    CHECK(decode(&s, &empty) == MVS_E_EMPTY);
    buffer type3 = { {3, 0, 0, 0}, 4 };
    CHECK(decode(&s, &type3) == MVS_E_UPDATE_TYPE);
    uint8_t quant[130] = {2};
    CHECK(mvs_decode(s.decoder, &s.surface, 0, 0, 0, 0, quant, 128, NULL, NULL, NULL) == MVS_E_QUANT_LENGTH);
    CHECK(mvs_decode(s.decoder, &s.surface, 0, 0, 0, 0, quant, 130, NULL, NULL, NULL) == MVS_E_QUANT_LENGTH);
    buffer bad_offset = FULL; bad_offset.bytes[5] = 5;
    CHECK(decode(&s, &bad_offset) == MVS_E_BODY_OFFSET);
    bad_offset.bytes[3] = 0xff;
    CHECK(decode(&s, &bad_offset) == MVS_E_BODY_OFFSET);
    buffer bad_header = full_update(15, 25, bits("0", "101 1 0000", marker("n", 0), NULL),
        bits("0 0 0", "00", "00", "1110 010 1", "0 01 0", "1", marker("m", 1), NULL));
    CHECK(decode(&s, &bad_header) == MVS_E_HEADER_MARKER);
    buffer bad_body = full_update(15, 25, bits("0", "101 1 0000", marker("m", 0), NULL),
        bits("0 0 0", "00", "00", "1110 010 1", "0 01 0", "1", marker("n", 1), NULL));
    CHECK(decode(&s, &bad_body) == MVS_E_BODY_MARKER);
    CHECK(decode(&s, &FULL) == MVS_OK);
    buffer bad_partial = partial_update(14, 19, bits("01", "000000", "0", EOB, "0", EOB, "00", marker("mvt", 2), NULL));
    CHECK(decode(&s, &bad_partial) == MVS_E_PARTIAL_MARKER);
    /* All-ones is no K.5 code */
    buffer bad_huffman = partial_update(14, 19, bits("01", "000000", "0", "1111111111111111", "0", EOB, "00", marker("mvs", 2), NULL));
    CHECK(decode(&s, &bad_huffman) == MVS_E_HUFFMAN);
    screen_free(&s);

    /* Repeat tile first: no previous DCT tile */
    screen r = screen_new(16, 8);
    buffer repeat = full_update(15, 25, bits("0", "101 1 0000", marker("m", 0), NULL), bits("1", "1", marker("m", 1), NULL));
    CHECK(decode(&r, &repeat) == MVS_E_REPEAT);
    screen_free(&r);

    /* Partial DCT tile before any full update */
    screen p = screen_new(16, 8);
    CHECK(decode(&p, &PARTIAL_UNCHANGED) == MVS_E_BASELINE);
    screen_free(&p);

    /* A unary prefix longer than the cap */
    screen q = screen_new(16, 8);
    char ones[1100]; memset(ones, '1', 1099); ones[1099] = 0;
    buffer rice = full_update(15, 25, bits("0", "101 1 0000", marker("m", 0), NULL), bits("0 0 0", ones, NULL));
    CHECK(decode(&q, &rice) == MVS_E_RICE);
    screen_free(&q);

    /* Resize resets the descriptors: the partial has no baseline */
    screen z = screen_new(16, 8);
    CHECK(decode(&z, &FULL) == MVS_OK);
    uint8_t *bigger = calloc(32 * 16, 4);
    mvs_surface big = { bigger, 32, 16, 32 * 4, 16, 8, 0 };
    CHECK(mvs_decode(z.decoder, &big, 0, 0, 16, 8, PARTIAL_UNCHANGED.bytes, PARTIAL_UNCHANGED.length, NULL, NULL, NULL) == MVS_E_BASELINE);
    free(bigger);
    screen_free(&z);

    /* Surface checks */
    screen g = screen_new(16, 8);
    mvs_surface bad = g.surface; bad.stride = 60;
    CHECK(mvs_decode(g.decoder, &bad, 0, 0, 16, 8, FULL.bytes, FULL.length, NULL, NULL, NULL) == MVS_E_ARGUMENT);
    bad = g.surface; bad.red_shift = 8;
    CHECK(mvs_decode(g.decoder, &bad, 0, 0, 16, 8, FULL.bytes, FULL.length, NULL, NULL, NULL) == MVS_E_ARGUMENT);
    CHECK(mvs_decode(g.decoder, &g.surface, 0, 1, 16, 8, FULL.bytes, FULL.length, NULL, NULL, NULL) == MVS_E_RECT);
    CHECK(mvs_decode(g.decoder, &g.surface, UINT32_MAX, 0, 16, 8, FULL.bytes, FULL.length, NULL, NULL, NULL) == MVS_E_RECT);
    screen_free(&g);
}

/* Slots run 1..64999 and wrap; slot 65000 is never written */
static void test_cache_bounds(void) {
    screen s = screen_new(16, 8);
    CHECK(decode(&s, &FULL) == MVS_OK);
    bool ok = true;
    for (int i = 0; i < 65000; i++) ok = ok && decode(&s, &PARTIAL_UNCHANGED) == MVS_OK;
    CHECK(ok);
    char idx[20];
    for (int i = 0; i < 16; i++) idx[i] = ((64999 >> (15 - i)) & 1) ? '1' : '0';
    idx[16] = 0;
    buffer last = partial_update(14, 19, bits("00", "11 0", idx, marker("mvs", 2), NULL));
    CHECK(decode(&s, &last) == MVS_OK);
    buffer next = partial_update(14, 19, bits("00", "11 1", marker("mvs", 2), NULL));
    CHECK(decode(&s, &next) == MVS_E_CACHE_SLOT);
    buffer zero = partial_update(14, 19, bits("00", "11 0 0000000000000000", marker("mvs", 2), NULL));
    CHECK(decode(&s, &zero) == MVS_E_CACHE_SLOT);
    screen_free(&s);
}

static void test_memory(void) {
    size_t tiles = 0, bytes = mvs_descriptor_bytes_for(3024, 1964, &tiles);
    CHECK(tiles == 378u * 246u);
    CHECK(tiles == 92988);
    screen s = screen_new(3024, 1964);
    CHECK(decode(&s, &FULL) == MVS_OK);
    size_t desc = 0, cache = 0, t = 0, total = mvs_memory_bytes(s.decoder, &desc, &cache, &t);
    CHECK(t == 92988 && desc == bytes && cache == 6435000 && total > desc + cache);
    printf("memory 3024x1964: tiles=%zu descriptor_bytes=%zu (%zu per tile) cache_bytes=%zu decoder_total=%zu framebuffer_bytes=%zu\n",
           t, desc, desc / t, cache, total, (size_t)3024 * 1964 * 4);
    screen_free(&s);
    screen huge = screen_new(16, 8);
    mvs_surface over = huge.surface; over.width = MVS_MAX_DIMENSION + 1; over.stride = (size_t)over.width * 4;
    CHECK(mvs_decode(huge.decoder, &over, 0, 0, 16, 8, FULL.bytes, FULL.length, NULL, NULL, NULL) == MVS_E_SIZE);
    screen_free(&huge);
}

/* Deterministic mutation fuzz over update sequences. Any result is
 * allowed; the sanitizers catch memory and undefined-behaviour faults. */
static uint64_t rng = 0x9e3779b97f4a7c15ull;
__attribute__((no_sanitize("integer"))) static uint32_t next_random(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)rng; }

static void test_fuzz(long iterations) {
    const buffer *seeds[] = { &FULL, &FULL_AC, &PARTIAL_CR_UP, &PARTIAL_UNCHANGED, &PARTIAL_CACHE_1, &PARTIAL_CACHE_NEXT, &PARTIAL_AC_1 };
    const size_t nseeds = sizeof seeds / sizeof *seeds;
    long errors = 0;
    uint8_t *pixels = calloc(40 * 24, 4);
    mvs_surface surface = { pixels, 40, 24, 40 * 4, 16, 8, 0 };
    mvs_decoder *d = mvs_create();
    for (long i = 0; i < iterations; i++) {
        if (i % 64 == 0) { mvs_destroy(d); d = mvs_create(); }
        buffer b = *seeds[next_random() % nseeds];
        unsigned flips = 1 + next_random() % 4;
        for (unsigned f = 0; f < flips && b.length; f++) {
            switch (next_random() % 4) {
            case 0: case 1: { size_t bit = next_random() % (b.length * 8); b.bytes[bit / 8] ^= (uint8_t)(0x80 >> (bit % 8)); break; }
            case 2: b.length = next_random() % (b.length + 1); break;
            case 3: if (b.length < sizeof b.bytes) b.bytes[b.length++] = (uint8_t)next_random(); break;
            }
        }
        uint32_t w = 1 + next_random() % 40, h = 1 + next_random() % 24;
        uint32_t x = next_random() % (41 - w), y = next_random() % (25 - h);
        mvs_stats stats;
        if (mvs_decode(d, &surface, x, y, w, h, b.bytes, b.length, NULL, NULL, &stats) != MVS_OK) errors++;
    }
    mvs_destroy(d);
    free(pixels);
    printf("fuzz: %ld iterations, %ld typed failures\n", iterations, errors);
}

int main(int argc, char **argv) {
    build_vectors();
    test_reference_vectors();
    test_idct_flat();
    test_malformed();
    test_cache_bounds();
    test_memory();
    test_fuzz(argc > 1 ? atol(argv[1]) : 200000);
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf("all decoder tests passed\n");
    return 0;
}
