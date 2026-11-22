/*
 * Owned MVS decoder tests, run under ASan and UBSan.
 *
 * The bitstream vectors and their expected pixels are ported from
 * noVNC-ARD ard/tests/test.mvs.js (MPL-2.0), commit
 * d699293635083c9e0c30c8f9480993865653772a. The malformed-input, cache
 * bound, resize and fuzz cases are new.
 *
 * Run as `test_mvs oracle`, every screen also feeds Screen Sharing's own
 * decoder (apple_oracle.h), and the two must agree.
 */
#include "apple_oracle.h"
#include "mvs.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures;
#define CHECK(cond) do { if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static bool oracle;                       /* Screen Sharing's decoder follows every screen */
static long both_decoded, both_pictures;  /* updates both decoded, and those whose pictures were compared */

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

/* A unary prefix of n ones */
static const char *ones(unsigned n) {
    static char text[48];
    memset(text, '1', n);
    text[n] = 0;
    return text;
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

/* A screen in the probe's pixel format: red 16, green 8, blue 0. Under the oracle Screen Sharing's
 * decoder gets the same updates. */
typedef struct {
    uint8_t *pixels;
    mvs_surface surface;
    mvs_decoder *decoder;
    apple_mvs *apple;
    bool apart; /* an update stopped midway or drew unspecified tiles: the two decoders no longer compare */
} screen;

static screen screen_new(uint32_t w, uint32_t h) {
    screen s = { calloc((size_t)w * h, 4), { NULL, w, h, (size_t)w * 4, 16, 8, 0 }, mvs_create(), NULL, false };
    s.surface.pixels = s.pixels;
    if (oracle) s.apple = apple_mvs_create(w, h);
    return s;
}
static void screen_free(screen *s) { mvs_destroy(s->decoder); apple_mvs_destroy(s->apple); free(s->pixels); }

/* Pixels whose red, green and blue differ between the two decoders */
static long picture_difference(const screen *s) {
    const mvs_surface *f = &s->surface;
    const uint8_t *theirs = apple_mvs_pixels(s->apple);
    long differing = 0;
    for (size_t i = 0; i < (size_t)f->width * f->height; i++) {
        uint32_t ours, apple;
        memcpy(&ours, s->pixels + i * 4, 4);
        memcpy(&apple, theirs + i * 4, 4);
        uint32_t rgb = ((ours >> f->red_shift & 0xff) << 16) | ((ours >> f->green_shift & 0xff) << 8) | (ours >> f->blue_shift & 0xff);
        differing += rgb != (apple & 0xffffff);
    }
    return differing;
}

/* Decodes one rect. Under the oracle Screen Sharing decodes it too: the two succeed or fail
 * together, and their pictures are equal after every update that both decoded to its end.
 * Screen Sharing gets no update that Remora refuses under a rule of its own: before decoding, at
 * the end of the payload, or at uninitialized pixels. */
static mvs_error screen_decode(screen *s, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const uint8_t *payload, size_t length,
                               mvs_written_fn written, void *context, mvs_stats *stats_out) {
    mvs_stats stats = { 0 };
    mvs_error e = mvs_decode(s->decoder, &s->surface, x, y, w, h, payload, length, written, context, &stats);
    if (stats_out) *stats_out = stats;
    if (e == MVS_E_ARGUMENT || e == MVS_E_ALLOCATION || e == MVS_E_SIZE || e == MVS_E_RECT || e == MVS_E_EMPTY || e == MVS_E_SHORT)
        return e;
    const bool own = e == MVS_E_OVERRUN || e == MVS_E_BASELINE;
    const bool midway = own || e == MVS_E_RICE || e == MVS_E_ZERO_RUN;
    if (s->apple && !s->apart && !own) {
        int status = apple_mvs_decode(s->apple, x, y, w, h, payload, length);
        long differing = midway || stats.unspecified ? 0 : picture_difference(s);
        both_decoded++;
        both_pictures += !midway && !stats.unspecified;
        if ((status == 0) != (e == MVS_OK) || differing) {
            failures++;
            s->apart = true;
            fprintf(stderr, "FAIL oracle: update type %u at %u,%u %ux%u, %zu bytes: Remora %d, Screen Sharing %d, %ld pixels differ\n",
                    length ? payload[0] : 0u, x, y, w, h, length, e, status, differing);
        }
    }
    s->apart |= midway || stats.unspecified;
    return e;
}

static mvs_error decode_at(screen *s, const buffer *p, uint32_t x, uint32_t y) {
    return screen_decode(s, x, y, 16, 8, p->bytes, p->length, NULL, NULL, NULL);
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
      CHECK(screen_decode(&s, 0, 0, 0, 0, tables, sizeof tables, NULL, NULL, NULL) == MVS_OK);
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
    /* A slot that was never written leaves its tile */
    { screen s = screen_new(16, 8);
      CHECK(decode(&s, &FULL) == MVS_OK);
      CHECK(decode(&s, &PARTIAL_CACHE_1) == MVS_OK);
      CHECK(rgb_is(&s, 8, 0, GRAY));
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

typedef struct { uint32_t x, y, w, h; } rectangle;
typedef struct { rectangle rectangles[2]; unsigned count; } writes;
static void record_write(void *context, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    writes *out = context;
    if (out->count < 2) out->rectangles[out->count] = (rectangle){x, y, w, h};
    out->count++;
}

static void test_written_tiles(void) {
    /* Off-origin tiles clipped by the display edge, with unchanged decoded bytes. */
    screen observed = screen_new(29, 13), plain = screen_new(29, 13);
    const buffer *updates[] = { &FULL, &PARTIAL_CR_UP, &PARTIAL_UNCHANGED, &PARTIAL_CACHE_1, &PARTIAL_CACHE_NEXT };
    for (unsigned i = 0; i < sizeof updates / sizeof *updates; i++) {
        writes out = {0};
        const buffer *p = updates[i];
        CHECK(screen_decode(&observed, 16, 8, 13, 5, p->bytes, p->length, record_write, &out, NULL) == MVS_OK);
        CHECK(screen_decode(&plain, 16, 8, 13, 5, p->bytes, p->length, NULL, NULL, NULL) == MVS_OK);
        CHECK(memcmp(observed.pixels, plain.pixels, 29 * 13 * 4) == 0);
        CHECK(out.count == (i == 0 ? 2u : 1u));
        rectangle first = out.rectangles[0];
        CHECK(first.x == (i < 3 ? 16u : 24u) && first.y == 8 && first.w == (i < 3 ? 8u : 5u) && first.h == 5);
        if (i == 0) {
            rectangle second = out.rectangles[1];
            CHECK(second.x == 24 && second.y == 8 && second.w == 5 && second.h == 5);
        }
    }
    screen_free(&observed); screen_free(&plain);
}

/* Every DC coefficient under the default and the largest quantizer */
static void test_idct_flat(void) {
    int16_t block[64] = {0};
    uint8_t quant[64] = {0}, out[64];
    int mismatches = 0;
    for (int step = 16; step <= 255; step += 239) {
        quant[0] = (uint8_t)step;
        for (int dc = -32768; dc <= 32767; dc++) {
            block[0] = (int16_t)dc;
            mvs_idct8x8(block, quant, out);
            uint8_t flat = mvs_idct_flat(dc * step);
            for (int i = 0; i < 64; i++) if (out[i] != flat) { mismatches++; break; }
        }
    }
    CHECK(mismatches == 0);
}

static void test_malformed(void) {
    /* Every prefix that cuts into the tiles fails, and none crashes. A full update also needs its
     * end marker; nothing checks the three bytes that end a partial update. */
    const buffer *all[] = { &FULL, &FULL_AC, &PARTIAL_CR_UP, &PARTIAL_UNCHANGED, &PARTIAL_AC_1 };
    const buffer *before[] = { NULL, NULL, &FULL, &FULL, &FULL_AC };
    for (size_t v = 0; v < sizeof all / sizeof *all; v++) {
        const size_t needed = all[v]->length - (before[v] ? 3 : 0);
        for (size_t len = 0; len < all[v]->length; len++) {
            screen s = screen_new(16, 8);
            if (before[v]) CHECK(decode(&s, before[v]) == MVS_OK);
            buffer cut = *all[v];
            cut.length = len;
            CHECK((decode(&s, &cut) == MVS_OK) == (len >= needed));
            screen_free(&s);
        }
    }
    screen s = screen_new(16, 8);
    buffer empty = { {0}, 0 };
    CHECK(decode(&s, &empty) == MVS_E_EMPTY);
    buffer type3 = { {3, 0, 0, 0}, 4 };
    CHECK(decode(&s, &type3) == MVS_E_UPDATE_TYPE);
    uint8_t quant[130] = {2};
    CHECK(screen_decode(&s, 0, 0, 0, 0, quant, 128, NULL, NULL, NULL) == MVS_E_QUANT_LENGTH);
    CHECK(screen_decode(&s, 0, 0, 0, 0, quant, 130, NULL, NULL, NULL) == MVS_E_QUANT_LENGTH);
    buffer bad_offset = FULL; bad_offset.bytes[3] = 0xff;
    CHECK(decode(&s, &bad_offset) == MVS_E_BODY_OFFSET);
    buffer bad_header = full_update(15, 25, bits("0", "101 1 0000", marker("n", 0), NULL),
        bits("0 0 0", "00", "00", "1110 010 1", "0 01 0", "1", marker("m", 1), NULL));
    CHECK(decode(&s, &bad_header) == MVS_E_HEADER_MARKER);
    buffer bad_body = full_update(15, 25, bits("0", "101 1 0000", marker("m", 0), NULL),
        bits("0 0 0", "00", "00", "1110 010 1", "0 01 0", "1", marker("n", 1), NULL));
    CHECK(decode(&s, &bad_body) == MVS_E_BODY_MARKER);
    screen_free(&s);

    /* Partial DCT tile before any full update */
    screen p = screen_new(16, 8);
    CHECK(decode(&p, &PARTIAL_UNCHANGED) == MVS_E_BASELINE);
    screen_free(&p);

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

/* Where Screen Sharing stops reading a code, and what it does then. */
static buffer pair(buffer body) { return full_update(15, 25, bits("0", "101 1 0000", marker("m", 0), NULL), body); }
static buffer whites(void) { return full_update(15, 25, bits("0", "000 1 0000", marker("m", 0), NULL), bits(marker("m", 1), NULL)); }

static void test_limits(void) {
    #define TILE "0 1 0 00"  /* a DCT tile that keeps the chroma DC, at threshold t1, with a luma DC step of 0 */
    #define TO_6 "000 000 000 000 000"
    #define RUN_OF_62 "0011 11 111 111 111 111 111 111 111 111"
    #define END "0010"
    #define REPEAT "1"
    #define UNCHECKED (-1), 0, 0
    /* Each update follows FULL on a fresh 16x8 screen. The colour is the first pixel's. */
    const struct { buffer update; mvs_error status; int r, g, b; } cases[] = {
        /* A DC value takes a prefix of 38 ones at most */
        { pair(bits("0 0 0", ones(38), "0 000 0", "00", "00", END, REPEAT, marker("m", 1), NULL)), MVS_OK, 128, 172, 0 },
        { pair(bits("0 0 0", ones(39), "0 000 0", "00", "00", END, REPEAT, marker("m", 1), NULL)), MVS_E_RICE, UNCHECKED },
        /* An AC value at positions 1 to 5 takes 32 */
        { pair(bits(TILE, "1", ones(32), "0 000 0", END, REPEAT, marker("m", 1), NULL)), MVS_OK, 27, 27, 27 },
        { pair(bits(TILE, "1", ones(33), "0 000 0", END, REPEAT, marker("m", 1), NULL)), MVS_E_RICE, UNCHECKED },
        /* A later AC value takes 18. Past that the block ends 20 bits into the prefix, drawn from what was read. */
        { pair(bits(TILE, TO_6, "1", ones(18), "0 000 0", END, REPEAT, marker("m", 1), NULL)), MVS_OK, 0, 0, 0 },
        { pair(bits(TILE, TO_6, "1", ones(19), "0", REPEAT, marker("m", 1), NULL)), MVS_OK, 128, 128, 128 },
        /* A long run of zeros may end at position 63 and not at 64 */
        { pair(bits(TILE, RUN_OF_62, "000", "000", REPEAT, marker("m", 1), NULL)), MVS_OK, 128, 128, 128 },
        { pair(bits(TILE, RUN_OF_62, "001", "000", REPEAT, marker("m", 1), NULL)), MVS_E_ZERO_RUN, UNCHECKED },
        /* A repeat with no DCT tile before it is a tile of zeros */
        { pair(bits(REPEAT, REPEAT, marker("m", 1), NULL)), MVS_OK, 128, 128, 128 },
        /* Sixteen ones are no Huffman code: the block ends after one more bit */
        { partial_update(14, 19, bits("01", "000000", "0", "1111111111111111 1", "0", EOB, "00", NULL)), MVS_OK, GRAY },
        /* A luma value of a partial update whose prefix is too long is 0, after 40 bits */
        { partial_update(14, 19, bits("01", "010000", "00000000000000", ones(40), "00", "0", EOB, "0", EOB, "00", NULL)), MVS_OK, GRAY },
        /* The three bytes that end a partial update may be anything */
        { partial_update(14, 19, bits("01", "000000", "0", EOB, "0", EOB, "00", marker("mvt", 2), NULL)), MVS_OK, GRAY },
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        screen s = screen_new(16, 8);
        CHECK(decode(&s, &FULL) == MVS_OK);
        mvs_error e = decode(&s, &cases[i].update);
        uint32_t px;
        memcpy(&px, s.pixels, 4);
        if (e != cases[i].status || (cases[i].r >= 0 && !rgb_is(&s, 0, 0, cases[i].r, cases[i].g, cases[i].b))) {
            failures++;
            fprintf(stderr, "FAIL limit case %zu: status %d, first tile %06x\n", i, e, px & 0xffffff);
        }
        screen_free(&s);
    }

    /* The block that ended early kept the descriptor FULL wrote, so a partial update refines FULL's tile. */
    screen s = screen_new(16, 8);
    buffer early = pair(bits(TILE, TO_6, "1", ones(19), "0", REPEAT, marker("m", 1), NULL));
    CHECK(decode(&s, &FULL) == MVS_OK);
    CHECK(decode(&s, &early) == MVS_OK);
    CHECK(decode(&s, &PARTIAL_UNCHANGED) == MVS_OK);
    CHECK(rgb_is(&s, 0, 0, GRAY));
    screen_free(&s);

    /* So does a descriptor under tiles of another type */
    s = screen_new(16, 8);
    buffer white = whites();
    CHECK(decode(&s, &FULL) == MVS_OK);
    CHECK(decode(&s, &white) == MVS_OK);
    CHECK(rgb_is(&s, 0, 0, 255, 255, 255));
    CHECK(decode(&s, &PARTIAL_CR_UP) == MVS_OK);
    CHECK(rgb_is(&s, 0, 0, REDDISH)); CHECK(rgb_is(&s, 8, 0, 255, 255, 255));
    screen_free(&s);

    /* At threshold 0 a partial update codes 64 values from the baselines after the first. The last
     * one grows from the 1 that follows them. */
    s = screen_new(16, 8);
    buffer zero_threshold = FULL, all_64 = partial_update(14, 19, bits("01", "111111",
        "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00",
        "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", "0000",
        "0", EOB, "0", EOB, "00", NULL));
    zero_threshold.bytes[1] = 0;
    CHECK(decode(&s, &zero_threshold) == MVS_OK);
    CHECK(decode(&s, &all_64) == MVS_OK);
    screen_free(&s);

    /* The body may start anywhere in the update, and the tile types may run on into it. Here the
     * body starts at the first byte: the six header bytes and the tile types are its first tile. */
    s = screen_new(16, 8);
    buffer overlapped = full_update(0, 0, bits("0", "101 1 0000", marker("m", 0), "0", END, REPEAT, marker("m", 1), NULL), bits(NULL));
    overlapped.bytes[5] = 0;
    CHECK(decode(&s, &overlapped) == MVS_OK);
    screen_free(&s);
    #undef TILE
    #undef TO_6
    #undef RUN_OF_62
    #undef END
    #undef REPEAT
    #undef UNCHECKED
}

/* Loads slot `index` into the second tile */
static buffer cache_load(unsigned index) {
    char text[17] = {0};
    for (int i = 0; i < 16; i++) text[i] = ((index >> (15 - i)) & 1) ? '1' : '0';
    return partial_update(14, 19, bits("00", "11 0", text, NULL));
}

/* Writes go to slots 1..64999 and wrap. Slot 65000 is never written, and loads as zeros once
 * 65000 entries were written. A slot that cannot be loaded leaves its tile. */
static void test_cache_bounds(void) {
    #define ZEROS 128, 128, 128
    screen s = screen_new(16, 8);
    buffer slot_1 = cache_load(1), slot_64999 = cache_load(64999), slot_65000 = cache_load(65000);
    buffer slot_0 = cache_load(0), slot_65001 = cache_load(65001), slot_65535 = cache_load(65535);
    CHECK(decode(&s, &FULL) == MVS_OK);
    CHECK(decode(&s, &PARTIAL_CR_UP) == MVS_OK); /* slot 1 */
    bool ok = true;
    for (int i = 2; i <= 64999; i++) ok = ok && decode(&s, &PARTIAL_UNCHANGED) == MVS_OK;
    CHECK(ok);
    CHECK(decode(&s, &slot_1) == MVS_OK); CHECK(rgb_is(&s, 8, 0, REDDISH));
    CHECK(decode(&s, &slot_65000) == MVS_OK); CHECK(rgb_is(&s, 8, 0, REDDISH)); /* only 64999 written */
    CHECK(decode(&s, &slot_64999) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY));
    CHECK(decode(&s, &slot_1) == MVS_OK);
    CHECK(decode(&s, &PARTIAL_UNCHANGED) == MVS_OK); /* the 65000th entry wraps to slot 1 */
    CHECK(decode(&s, &slot_1) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY));
    CHECK(decode(&s, &slot_65000) == MVS_OK); CHECK(rgb_is(&s, 8, 0, ZEROS));
    CHECK(decode(&s, &slot_1) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY));
    CHECK(decode(&s, &slot_0) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY));
    CHECK(decode(&s, &slot_65001) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY));
    CHECK(decode(&s, &slot_65535) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY));
    CHECK(decode(&s, &slot_64999) == MVS_OK);
    CHECK(decode(&s, &PARTIAL_CACHE_NEXT) == MVS_OK); CHECK(rgb_is(&s, 8, 0, ZEROS)); /* slot 65000 */
    CHECK(decode(&s, &FULL) == MVS_OK);
    CHECK(decode(&s, &PARTIAL_CACHE_NEXT) == MVS_OK); CHECK(rgb_is(&s, 8, 0, GRAY)); /* slot 65001 */
    screen_free(&s);
    #undef ZEROS
}

static void test_memory(void) {
    size_t tiles = 0, bytes = mvs_descriptor_bytes_for(3024, 1964, &tiles);
    CHECK(tiles == 378u * 246u);
    CHECK(tiles == 92988);
    screen s = screen_new(3024, 1964);
    CHECK(decode(&s, &FULL) == MVS_OK);
    size_t desc = 0, cache = 0, t = 0, total = mvs_memory_bytes(s.decoder, &desc, &cache, &t);
    CHECK(t == 92988 && desc == bytes && cache == 6435099 && total > desc + cache);
    printf("memory 3024x1964: tiles=%zu descriptor_bytes=%zu (%zu per tile) cache_bytes=%zu decoder_total=%zu framebuffer_bytes=%zu\n",
           t, desc, desc / t, cache, total, (size_t)3024 * 1964 * 4);
    screen_free(&s);
    screen huge = screen_new(16, 8);
    mvs_surface over = huge.surface; over.width = MVS_MAX_DIMENSION + 1; over.stride = (size_t)over.width * 4;
    CHECK(mvs_decode(huge.decoder, &over, 0, 0, 16, 8, FULL.bytes, FULL.length, NULL, NULL, NULL) == MVS_E_SIZE);
    screen_free(&huge);
}

typedef struct { uint8_t *bytes; size_t bits; } bit_writer; /* bytes start zeroed */
static void put_bits(bit_writer *w, uint32_t value, unsigned n) {
    for (unsigned i = n; i > 0; i--) {
        if ((value >> (i - 1)) & 1) w->bytes[w->bits / 8] |= (uint8_t)(0x80 >> (w->bits % 8));
        w->bits++;
    }
}

/* A fresh screen after one full update that draws every tile as the same gray DCT tile, so that
 * partial updates find a baseline everywhere. */
static screen primed_screen(uint32_t w, uint32_t h) {
    screen s = screen_new(w, h);
    const uint32_t tiles = ((w + 7) / 8) * ((h + 7) / 8);
    const size_t offset = 6 + (1 + 4 * (size_t)tiles + 8 + 7) / 8;
    uint8_t *payload = calloc(offset + tiles / 8 + 4, 1);
    bit_writer header = { payload + 6, 0 }, body = { payload + offset, 0 };
    payload[1] = 15; payload[2] = 25; payload[4] = (uint8_t)(offset >> 8); payload[5] = (uint8_t)offset;
    put_bits(&header, 0, 1);
    for (uint32_t i = 0; i < tiles; i++) put_bits(&header, 5 << 1, 4);
    put_bits(&header, 0x6d, 8);
    put_bits(&body, 0x82, 9); /* no repeat, the chroma DC kept, threshold t1, luma DC step 0, end of block */
    for (uint32_t i = 1; i < tiles; i++) put_bits(&body, 1, 1); /* repeats */
    put_bits(&body, 0x6d, 8);
    CHECK(screen_decode(&s, 0, 0, w, h, payload, offset + (body.bits + 7) / 8, NULL, NULL, NULL) == MVS_OK);
    free(payload);
    return s;
}

/* Deterministic mutation fuzz over update sequences. Any result is
 * allowed; the sanitizers catch memory and undefined-behaviour faults. */
static uint64_t rng = 0x9e3779b97f4a7c15ull;
__attribute__((no_sanitize("integer"))) static uint32_t next_random(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)rng; }

static void test_fuzz(long iterations) {
    const buffer *seeds[] = { &FULL, &FULL_AC, &PARTIAL_CR_UP, &PARTIAL_UNCHANGED, &PARTIAL_CACHE_1, &PARTIAL_CACHE_NEXT, &PARTIAL_AC_1 };
    const size_t nseeds = sizeof seeds / sizeof *seeds;
    long errors = 0;
    screen s = primed_screen(40, 24);
    for (long i = 0; i < iterations; i++) {
        /* Under the oracle a screen is of use only while the two decoders compare. */
        if (i % 64 == 0 || (oracle && s.apart)) { screen_free(&s); s = primed_screen(40, 24); }
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
        if (screen_decode(&s, x, y, w, h, b.bytes, b.length, NULL, NULL, NULL) != MVS_OK) errors++;
    }
    screen_free(&s);
    printf("fuzz: %ld iterations, %ld typed failures\n", iterations, errors);
}

static void test_regional_initialization(void) {
    screen s = screen_new(48, 24);
    /* Two displays initialize in separate messages with unused desktop between them. */
    CHECK(decode_at(&s, &FULL, 32, 0) == MVS_OK);
    CHECK(decode_at(&s, &FULL, 0, 16) == MVS_OK);
    CHECK(decode_at(&s, &PARTIAL_CR_UP, 32, 0) == MVS_OK);
    CHECK(decode_at(&s, &PARTIAL_CR_UP, 0, 16) == MVS_OK);
    CHECK(rgb_is(&s, 32, 0, REDDISH));
    CHECK(rgb_is(&s, 0, 16, REDDISH));
    /* A skip still depends on existing pixels, even without DCT coefficients. */
    buffer skip = partial_update(14, 19, bits("00 00", marker("mvs", 2), NULL));
    CHECK(decode_at(&s, &skip, 16, 8) == MVS_E_BASELINE);
    screen_free(&s);
    s = screen_new(16, 8);
    CHECK(decode(&s, &skip) == MVS_E_BASELINE);
    screen_free(&s);
}

static void test_raw_coverage_and_geometry_reset(void) {
    screen s=screen_new(16,8);
    s.apart=true; /* Raw coverage is Remora's own: Screen Sharing has nothing to compare. */
    buffer skip=partial_update(14,19,bits("00 00",marker("mvs",2),NULL));
    CHECK(mvs_mark_raw(s.decoder,16,8,0,0,16,4)==MVS_OK);
    CHECK(!mvs_region_initialized(s.decoder,0,0,16,8));
    CHECK(decode(&s,&skip)==MVS_E_BASELINE);
    CHECK(mvs_mark_raw(s.decoder,16,8,0,4,16,4)==MVS_OK);
    CHECK(mvs_region_initialized(s.decoder,0,0,16,8));
    CHECK(decode(&s,&skip)==MVS_OK);
    CHECK(decode(&s,&PARTIAL_CR_UP)==MVS_E_BASELINE);
    CHECK(decode(&s,&FULL)==MVS_OK);
    CHECK(mvs_mark_raw(s.decoder,16,8,1,1,1,1)==MVS_OK);
    CHECK(decode(&s,&PARTIAL_CR_UP)==MVS_OK);
    CHECK(rgb_is(&s,0,0,REDDISH));
    mvs_reset_picture(s.decoder);
    CHECK(!mvs_region_initialized(s.decoder,0,0,16,8));
    CHECK(decode(&s,&skip)==MVS_E_BASELINE);
    /* A covered screen loses its coverage when the geometry changes. */
    CHECK(mvs_mark_raw(s.decoder,16,8,0,0,16,8)==MVS_OK);
    CHECK(mvs_region_initialized(s.decoder,0,0,16,8));
    CHECK(mvs_mark_raw(s.decoder,16,16,0,0,16,8)==MVS_OK);
    CHECK(!mvs_region_initialized(s.decoder,0,0,16,16));
    CHECK(mvs_region_initialized(s.decoder,0,0,16,8));
    screen_free(&s);
}

/* Generated update sequences over a larger screen. Their structured headers
 * reach every tile type, every threshold, custom quantization and the cache,
 * and random bodies reach transforms that wrap. test_limits covers the codes
 * Screen Sharing stops at. The hash covers the result, statistics, written
 * rectangles and pixels of every update, so a faster decoder must reproduce
 * this one bit for bit. The oracle compares the same updates, so the hash is
 * of output Screen Sharing agrees with wherever the two compare. */
static uint64_t golden_state;
__attribute__((no_sanitize("integer"))) static uint32_t golden_random(void) {
    uint64_t z = (golden_state += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return (uint32_t)((z ^ (z >> 31)) >> 32);
}

static uint64_t golden_hash = 0xcbf29ce484222325ull;
__attribute__((no_sanitize("integer"))) static void hash_bytes(const void *data, size_t n) {
    const uint8_t *p = data;
    for (size_t i = 0; i < n; i++) golden_hash = (golden_hash ^ p[i]) * 0x100000001b3ull;
}
static void hash_write(void *context, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    (void)context;
    const uint32_t r[4] = { x, y, w, h };
    hash_bytes(r, sizeof r);
}

static unsigned golden_type(void) {
    static const uint8_t weights[8] = { 3, 5, 5, 8, 12, 55, 6, 6 };
    unsigned pick = golden_random() % 100;
    for (unsigned t = 0; t < 8; t++) {
        if (pick < weights[t]) return t;
        pick -= weights[t];
    }
    return 5;
}

/* ---- Valid refinement streams ----
 * A full update codes each coefficient as a multiple of a coarse step, and the
 * partial update of the same region adds the remainder. The generator writes
 * that pair for one region: text-like, smooth and flat DCT tiles, white tiles
 * the partial skips, copies it matches, and cache loads. */

/* `ones` one bits, a zero, `nbits` low bits, then the sign. */
static void put_code(bit_writer *w, unsigned ones, unsigned low, unsigned nbits, bool negative) {
    for (unsigned i = 0; i < ones; i++) put_bits(w, 1, 1);
    put_bits(w, 0, 1);
    put_bits(w, low, nbits);
    put_bits(w, negative, 1);
}

static void put_dc_rice(bit_writer *w, int v) {
    unsigned m = (unsigned)abs(v);
    if (m < 2) put_bits(w, m ? 2u | (v < 0) : 0, m ? 3 : 2);
    else if (m < 4) put_code(w, 1, m - 2, 1, v < 0);
    else if (m < 8) put_code(w, 2, m - 4, 2, v < 0);
    else put_code(w, m / 8 + 2, m % 8, 3, v < 0);
}

static void put_full_ac(bit_writer *w, int raw, unsigned pos) {
    unsigned m = (unsigned)abs(raw);
    if (m < 2) { put_bits(w, m ? 2u | (raw < 0) : 0, 3); return; }
    put_bits(w, 1, 1);
    if (pos <= 5 && m < 18) put_code(w, (m - 2) / 4, (m - 2) % 4, 2, raw < 0);
    else if (pos <= 5) put_code(w, 4 + (m - 18) / 8, (m - 18) % 8, 3, raw < 0);
    else if (m < 4) put_code(w, 0, m - 2, 1, raw < 0);
    else if (m < 8) put_code(w, 1, m - 4, 2, raw < 0);
    else put_code(w, m / 8 + 1, m % 8, 3, raw < 0);
}

static void put_chroma_dc(bit_writer *w, int fine) {
    if (fine / 2) put_bits(w, (unsigned)abs(fine) & 1, 1);
    else put_bits(w, fine ? 2u | (fine < 0) : 0, fine ? 2 : 1);
}

static void put_chroma_ac(bit_writer *w, unsigned count, unsigned limit) {
    static const uint8_t code[2][2] = { { 0, 1 }, { 12, 27 } }, length[2][2] = { { 2, 2 }, { 4, 5 } }; /* K.5, run 0..1, size 1..2 */
    unsigned k = 0;
    for (; count > 0 && k + 1 < limit; count--) {
        unsigned run = golden_random() % 2, size = golden_random() % 2;
        put_bits(w, code[run][size], length[run][size]);
        put_bits(w, golden_random(), size + 1);
        k += run + 1;
    }
    if (k < limit) put_bits(w, 10, 4);
}

static unsigned coarse_shift(unsigned pos, unsigned threshold) {
    if (threshold > 14) return pos <= 5 || pos < threshold ? 1 : 3;
    return pos < threshold ? 3 : 4;
}

typedef struct { uint8_t *full, *partial; size_t full_length, partial_length; } refinement;
static uint64_t refinement_cached, refinement_loaded; /* the decoder's cache count and last loaded slot */

static refinement refinement_new(uint32_t w, uint32_t h, unsigned t1, unsigned t2) {
    uint32_t tiles_x = (w + 7) / 8;
    size_t tiles = (size_t)tiles_x * ((h + 7) / 8), offset = 6 + (1 + tiles * 4 + 8 + 7) / 8;
    refinement r = { calloc(offset + tiles * 96 + 64, 1), calloc(tiles * 96 + 64, 1), 0, 0 };
    bit_writer header = { r.full + 6, 0 }, body = { r.full + offset, 0 }, partial = { r.partial + 3, 0 };
    r.full[1] = (uint8_t)t1; r.full[2] = (uint8_t)t2;
    r.full[3] = (uint8_t)(offset >> 16); r.full[4] = (uint8_t)(offset >> 8); r.full[5] = (uint8_t)offset;
    r.partial[0] = 1; r.partial[1] = 14; r.partial[2] = 19;
    put_bits(&header, 0, 1);
    int state_y = 0, state_cb = 0, state_cr = 0;
    for (size_t i = 0; i < tiles; i++) {
        unsigned pick = golden_random() % 100, type = pick < 60 ? 5 : pick < 88 ? 0 : pick < 94 ? 1 : 2;
        if ((type == 1 && i % tiles_x == 0) || (type == 2 && i < tiles_x)) type = 5; /* a copy reads inside the region */
        put_bits(&header, type << 1, 4);
        if (type != 5) { put_bits(&partial, type ? 2 : 0, 2); continue; }

        /* The picture: 70% text-like tiles, 20% smooth, 10% flat; a quarter carry colour. */
        int fine[64] = {0};
        unsigned shape = golden_random() % 10, count = shape < 7 ? 20 + golden_random() % 44 : shape < 9 ? golden_random() % 12 : 0;
        unsigned threshold_bit = golden_random() % 2, threshold = threshold_bit ? t2 : t1, last = 0;
        bool colour = golden_random() % 4 == 0;
        fine[0] = (int)(golden_random() % 128) - 64;
        int fine_cb = colour ? (int)(golden_random() % 64) - 32 : 0, fine_cr = colour ? (int)(golden_random() % 64) - 32 : 0;
        for (unsigned pos = 1; pos <= count; pos++) {
            if (golden_random() % 100 >= (shape < 7 ? 60u : 40u)) continue;
            int magnitude = 1 + (int)(golden_random() % (1 + (shape < 7 ? 160u : 24u) / (4 + pos)));
            fine[pos] = golden_random() % 2 ? -magnitude : magnitude;
            if (fine[pos] / (1 << coarse_shift(pos, threshold))) last = pos;
        }

        put_bits(&body, threshold_bit, 3); /* not a repeat, coded chroma DC, threshold */
        put_dc_rice(&body, state_cb / 2 - fine_cb / 2);
        put_dc_rice(&body, state_cr / 2 - fine_cr / 2);
        put_dc_rice(&body, state_y - fine[0]);
        state_y = fine[0]; state_cb = fine_cb / 2 * 2; state_cr = fine_cr / 2 * 2;
        for (unsigned pos = 1; pos <= last; pos++) put_full_ac(&body, fine[pos] / (1 << coarse_shift(pos, threshold)), pos);
        if (last < 63) put_bits(&body, 2, 4);

        uint64_t slots = refinement_cached < MVS_CACHE_SLOTS - 1 ? refinement_cached : MVS_CACHE_SLOTS - 1;
        if (slots && golden_random() % 100 < 8) {
            if (refinement_loaded < slots && golden_random() % 2) { refinement_loaded++; put_bits(&partial, 7, 3); }
            else { refinement_loaded = 1 + golden_random() % slots; put_bits(&partial, 6, 3); put_bits(&partial, (uint32_t)refinement_loaded, 16); }
            continue;
        }
        refinement_cached++;
        put_bits(&partial, 1, 2);
        put_bits(&partial, count, 6);
        for (unsigned pos = 1; pos <= count; pos++) {
            unsigned shift = coarse_shift(pos, threshold);
            int v = fine[pos], coarse = v / (1 << shift);
            if (coarse) put_bits(&partial, (unsigned)abs(v) & ((1u << shift) - 1), shift);
            else if (shift == 1) put_bits(&partial, v ? 2u | (v < 0) : 0, v ? 2 : 1);
            else put_dc_rice(&partial, v);
        }
        put_chroma_dc(&partial, fine_cr);
        put_chroma_ac(&partial, colour ? golden_random() % 5 : 0, 14);
        put_chroma_dc(&partial, fine_cb);
        put_chroma_ac(&partial, colour ? golden_random() % 5 : 0, 19);
    }
    put_bits(&header, 0x6d, 8);
    put_bits(&body, 0x6d, 8);
    put_bits(&partial, 0x6d7673, 24);
    r.full_length = offset + (body.bits + 7) / 8;
    r.partial_length = 3 + (partial.bits + 7) / 8;
    return r;
}
static void refinement_free(refinement *r) { free(r->full); free(r->partial); }

/* The adapter's geometry: whole tiles, clipped only by the framebuffer edge. */
static void tile_rect(uint32_t width, uint32_t height, uint32_t *x, uint32_t *y, uint32_t *w, uint32_t *h) {
    const uint32_t tiles_x = (width + 7) / 8, tiles_y = (height + 7) / 8;
    *x = 8 * (golden_random() % tiles_x); *y = 8 * (golden_random() % tiles_y);
    *w = 8 * (1 + golden_random() % (tiles_x - *x / 8)); *h = 8 * (1 + golden_random() % (tiles_y - *y / 8));
    if (*x + *w > width) *w = width - *x;
    if (*y + *h > height) *h = height - *y;
}

static void test_golden_sequence(void) {
    enum { W = 157, H = 99, UPDATES = 4000 };
    static uint8_t payload[1 << 16], header_bytes_buffer[16384];
    bit_writer header = { header_bytes_buffer, 0 };
    screen s = primed_screen(W, H);
    s.surface.red_shift = 0; s.surface.blue_shift = 16;
    golden_state = 21;
    long errors = 0, restarts = 0;
    for (int i = 0; i < UPDATES; i++) {
        /* A decoder that stopped midway is of no further use. */
        if (s.apart) {
            screen_free(&s);
            s = primed_screen(W, H);
            s.surface.red_shift = 0; s.surface.blue_shift = 16;
            restarts++;
        }
        /* Three rects in four are whole tiles, as the adapter passes them. */
        uint32_t x, y, w, h;
        if (golden_random() % 4) tile_rect(W, H, &x, &y, &w, &h);
        else {
            w = 1 + golden_random() % W; h = 1 + golden_random() % H;
            x = golden_random() % (W - w + 1); y = golden_random() % (H - h + 1);
        }
        size_t tiles = (size_t)((w + 7) / 8) * ((h + 7) / 8), length;
        unsigned kind = golden_random() % 100;
        if (kind < 6) {
            payload[0] = 2;
            unsigned range = golden_random() % 3 ? 32 : 255;
            for (int q = 1; q < 129; q++) payload[q] = (uint8_t)(1 + golden_random() % range);
            length = 129;
        } else if (kind < 50) {
            memset(header_bytes_buffer, 0, sizeof header_bytes_buffer);
            header.bits = 0;
            put_bits(&header, 0, 1);
            for (size_t done = 0; done < tiles;) {
                unsigned type = golden_type(), form = golden_random() % 100;
                uint32_t count = 1;
                put_bits(&header, type, 3);
                if (form < 75) put_bits(&header, 0, 1);
                else if (form < 95) { uint32_t v = golden_random() % 15; put_bits(&header, 1, 1); put_bits(&header, v, 4); count = v + 2; }
                else {
                    uint32_t v = golden_random() % 300;
                    put_bits(&header, 1, 1); put_bits(&header, 15, 4);
                    if (v < 128) put_bits(&header, v, 8);
                    else { put_bits(&header, 0x80 | (v & 0x7f), 8); put_bits(&header, v >> 7, 8); }
                    count = v + 17;
                }
                done += count;
            }
            put_bits(&header, 0x6d, 8);
            size_t header_bytes = (header.bits + 7) / 8, body = tiles * 10 + 16, offset = 6 + header_bytes;
            payload[0] = 0;
            payload[1] = (uint8_t)(golden_random() % 2 ? golden_random() % 15 : 15 + golden_random() % 49);
            payload[2] = (uint8_t)(golden_random() % 2 ? golden_random() % 15 : 15 + golden_random() % 49);
            payload[3] = (uint8_t)(offset >> 16); payload[4] = (uint8_t)(offset >> 8); payload[5] = (uint8_t)offset;
            memcpy(payload + 6, header.bytes, header_bytes);
            for (size_t b = 0; b < body; b++) payload[offset + b] = (uint8_t)golden_random();
            length = offset + body;
        } else {
            payload[0] = 1;
            payload[1] = (uint8_t)(golden_random() % 70);
            payload[2] = (uint8_t)(golden_random() % 70);
            length = 3 + tiles * 12 + 8;
            for (size_t b = 3; b < length; b++) payload[b] = (uint8_t)golden_random();
        }
        mvs_stats stats;
        mvs_error e = screen_decode(&s, x, y, w, h, payload, length, hash_write, NULL, &stats);
        if (e) errors++;
        hash_bytes(&e, sizeof e);
        hash_bytes(&stats, sizeof stats);
        hash_bytes(s.pixels, (size_t)W * H * 4);
    }
    screen_free(&s);
    printf("golden: %d updates, %ld typed failures, %ld restarts, hash %016llx\n", UPDATES, errors, restarts, (unsigned long long)golden_hash);
    CHECK(golden_hash == 0x63004a80f1c7029bull);
}

/* Every code of a valid partial update, in both threshold ranges and with
 * custom quantization, pinned like the golden sequence. */
static void test_refinement_sequence(void) {
    enum { W = 157, H = 99, REGIONS = 300 };
    screen s = screen_new(W, H);
    golden_state = 22;
    golden_hash = 0xcbf29ce484222325ull;
    refinement_cached = refinement_loaded = 0;
    long errors = 0;
    for (int i = 0; i < REGIONS; i++) {
        mvs_stats stats;
        if (i % 16 == 15) {
            uint8_t quant[129] = { 2 };
            unsigned range = golden_random() % 3 ? 32 : 255;
            for (int q = 1; q < 129; q++) quant[q] = (uint8_t)(1 + golden_random() % range);
            if (screen_decode(&s, 0, 0, 0, 0, quant, sizeof quant, NULL, NULL, NULL)) errors++;
        }
        uint32_t x, y, w, h;
        tile_rect(W, H, &x, &y, &w, &h);
        unsigned t1 = golden_random() % 2 ? 1 + golden_random() % 14 : 15 + golden_random() % 49;
        unsigned t2 = golden_random() % 2 ? 1 + golden_random() % 14 : 15 + golden_random() % 49;
        refinement r = refinement_new(w, h, t1, t2);
        const uint8_t *payloads[2] = { r.full, r.partial };
        const size_t lengths[2] = { r.full_length, r.partial_length };
        for (int p = 0; p < 2; p++) {
            if (screen_decode(&s, x, y, w, h, payloads[p], lengths[p], hash_write, NULL, &stats)) errors++;
            hash_bytes(&stats, sizeof stats);
            hash_bytes(s.pixels, (size_t)W * H * 4);
        }
        refinement_free(&r);
    }
    CHECK(!s.apart);
    screen_free(&s);
    printf("refinement: %d regions, %ld typed failures, hash %016llx\n", REGIONS, errors, (unsigned long long)golden_hash);
    CHECK(errors == 0);
    CHECK(golden_hash == 0x2acb0d9eff57fbe2ull);
}

/* ---- The transform, compared block by block ----
 * Coefficients up to the whole int16 range under quantizers from 0 to 255, where the 32-bit
 * arithmetic wraps, and sparse blocks, whose columns without AC coefficients take libjpeg's
 * shortcut. */
static void test_idct(void) {
    enum { BLOCKS = 300000 };
    long differing = 0;
    golden_state = 24;
    golden_hash = 0xcbf29ce484222325ull;
    for (int i = 0; i < BLOCKS; i++) {
        int16_t coefficients[64];
        uint16_t wide_quant[64];
        uint8_t quant[64], ours[64], theirs[64];
        const uint32_t bound = 1u << (1 + golden_random() % 15), most = golden_random() % 3 ? 32 : 255;
        const uint32_t one_in = 1u << (golden_random() % 5);
        bool flat = true;
        for (int k = 0; k < 64; k++) {
            int value = golden_random() % one_in ? 0 : (int)(golden_random() % (2 * bound)) - (int)bound;
            if (k == 0 && golden_random() % 2) value = (int)(golden_random() % 65536) - 32768;
            coefficients[k] = (int16_t)value;
            wide_quant[k] = quant[k] = (uint8_t)(golden_random() % (most + 1));
            flat = flat && (k == 0 || value == 0);
        }
        mvs_idct8x8(coefficients, quant, ours);
        if (flat) for (int k = 0; k < 64; k++) CHECK(ours[k] == mvs_idct_flat(coefficients[0] * quant[0]));
        hash_bytes(ours, sizeof ours);
        if (!oracle) continue;
        apple_idct(coefficients, wide_quant, theirs);
        differing += memcmp(ours, theirs, sizeof ours) != 0;
    }
    printf("idct: %d blocks, hash %016llx", BLOCKS, (unsigned long long)golden_hash);
    if (oracle) printf(", %ld differ from Screen Sharing's", differing);
    printf("\n");
    CHECK(differing == 0);
    CHECK(golden_hash == 0xa86e0b1feb775da7ull);
}

/* ---- Full updates whose coefficients are as large as the codes carry ----
 * Every tile is a DCT tile under quantizers up to 255. The luma DC walks across the 160 tiles
 * of an update until it wraps at 16 bits. */
static void test_large_coefficients(void) {
    enum { W = 160, H = 64, TILES = W / 8 * (H / 8), UPDATES = 600, OFFSET = 6 + (1 + TILES * 4 + 8 + 7) / 8 };
    static uint8_t payload[OFFSET + TILES * 400];
    screen s = screen_new(W, H);
    golden_state = 25;
    golden_hash = 0xcbf29ce484222325ull;
    long errors = 0;
    for (int i = 0; i < UPDATES; i++) {
        uint8_t quant[129] = { 2 };
        unsigned range = golden_random() % 3 ? 255 : 32;
        for (int q = 1; q < 129; q++) quant[q] = (uint8_t)(1 + golden_random() % range);
        if (screen_decode(&s, 0, 0, 0, 0, quant, sizeof quant, NULL, NULL, NULL)) errors++;

        memset(payload, 0, sizeof payload);
        bit_writer header = { payload + 6, 0 }, body = { payload + OFFSET, 0 };
        payload[1] = (uint8_t)(golden_random() % 64); payload[2] = (uint8_t)(golden_random() % 64);
        payload[4] = OFFSET >> 8; payload[5] = OFFSET & 0xff;
        put_bits(&header, 0, 1);
        for (int t = 0; t < TILES; t++) put_bits(&header, 5 << 1, 4);
        put_bits(&header, 0x6d, 8);
        const bool down = golden_random() % 2;
        for (int t = 0; t < TILES; t++) {
            if (t && golden_random() % 8 == 0) { put_bits(&body, 1, 1); continue; } /* a repeat */
            const unsigned coded_chroma = golden_random() % 2, density = golden_random() % 4;
            put_bits(&body, 0, 1);
            put_bits(&body, !coded_chroma, 1);
            put_bits(&body, golden_random() % 2, 1);
            if (coded_chroma) for (int c = 0; c < 2; c++) put_dc_rice(&body, (int)(golden_random() % 591) - 295);
            /* Mostly one way, so that the DC adds up */
            int step = (int)(golden_random() % 296);
            put_dc_rice(&body, (golden_random() % 8 == 0) != down ? -step : step);
            unsigned last = density ? golden_random() % 64 : 0;
            for (unsigned pos = 1; pos <= last; pos++) {
                const int most = pos <= 5 ? 249 : 143;
                int raw = golden_random() % 4 < density ? (int)(golden_random() % (2 * (unsigned)most + 1)) - most : 0;
                if (golden_random() % 4 == 0 && raw) raw = raw < 0 ? -most : most;
                put_full_ac(&body, raw, pos);
            }
            if (last < 63) put_bits(&body, 2, 4);
        }
        put_bits(&body, 0x6d, 8);
        if (screen_decode(&s, 0, 0, W, H, payload, OFFSET + (body.bits + 7) / 8, NULL, NULL, NULL)) errors++;
        hash_bytes(s.pixels, (size_t)W * H * 4);
    }
    CHECK(!s.apart);
    screen_free(&s);
    printf("large coefficients: %d updates, %ld typed failures, hash %016llx\n", UPDATES, errors, (unsigned long long)golden_hash);
    CHECK(errors == 0);
    CHECK(golden_hash == 0x4d4aaa480756e814ull);
}

/* ---- Benchmark: partial updates on a 3024x1964 desktop ----
 * Each region gets its coarse full update untimed, then its refining partial
 * update timed, with the adapter's statistics and written-tile callback. */
static void count_written(void *context, uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    (void)x; (void)y;
    *(uint64_t *)context += (uint64_t)w * h;
}
static int compare_times(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

static void bench(void) {
    enum { W = 3024, H = 1964, ROUNDS = 15, KINDS = 2, MOST = 96 };
    static const struct { const char *name; uint32_t w, h; int count; } kinds[KINDS] = {
        { "text edit", 640, 32, MOST }, { "scroll", 1200, 800, 8 },
    };
    static uint64_t times[KINDS][ROUNDS * MOST];
    uint8_t *pixels = calloc((size_t)W * H, 4);
    mvs_surface surface = { pixels, W, H, W * 4, 16, 8, 0 };
    uint64_t written = 0;
    for (int round = 0; round < ROUNDS; round++) {
        mvs_decoder *d = mvs_create();
        golden_state = 23;
        refinement_cached = refinement_loaded = 0;
        for (int k = 0; k < KINDS; k++) {
            for (int i = 0; i < kinds[k].count; i++) {
                uint32_t w = kinds[k].w, h = kinds[k].h;
                uint32_t x = 8 * (golden_random() % ((W - w) / 8 + 1)), y = 8 * (golden_random() % ((H - h) / 8 + 1));
                refinement r = refinement_new(w, h, 15, 25);
                mvs_stats stats;
                CHECK(mvs_decode(d, &surface, x, y, w, h, r.full, r.full_length, count_written, &written, &stats) == MVS_OK);
                uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                mvs_error e = mvs_decode(d, &surface, x, y, w, h, r.partial, r.partial_length, count_written, &written, &stats);
                times[k][round * kinds[k].count + i] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
                CHECK(e == MVS_OK);
                refinement_free(&r);
            }
        }
        mvs_destroy(d);
    }
    for (int k = 0; k < KINDS; k++) {
        int n = ROUNDS * kinds[k].count;
        qsort(times[k], (size_t)n, sizeof times[k][0], compare_times);
        double median = (double)times[k][n / 2] / 1000.0, megapixels = (double)kinds[k].w * kinds[k].h / 1e6;
        printf("bench %-9s %4ux%-4u median %9.1f us/update  %7.1f megapixels/s  %6.1f ns/tile  (%d updates)\n", kinds[k].name,
               kinds[k].w, kinds[k].h, median, megapixels / (median / 1e6), median * 1000.0 / (kinds[k].w / 8 * (kinds[k].h / 8)), n);
    }
    golden_hash = 0xcbf29ce484222325ull;
    hash_bytes(pixels, (size_t)W * H * 4);
    printf("bench written pixels %llu, final picture hash %016llx\n", (unsigned long long)written, (unsigned long long)golden_hash);
    free(pixels);
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "bench")) { bench(); return failures != 0; }
    long fuzz = argc > 1 ? atol(argv[1]) : 200000;
    if (argc > 1 && !strcmp(argv[1], "oracle")) {
        const char *unavailable = apple_oracle_load();
        if (unavailable) {
            printf("oracle skipped: Screen Sharing's decoder cannot be called here: %s\n", unavailable);
            return 0;
        }
        printf("oracle: comparing with %s\n", apple_oracle_identity());
        oracle = true;
        fuzz = 200000;
    }
    build_vectors();
    test_regional_initialization();
    test_raw_coverage_and_geometry_reset();
    test_reference_vectors();
    test_written_tiles();
    test_idct_flat();
    test_idct();
    test_malformed();
    test_limits();
    test_cache_bounds();
    test_memory();
    test_large_coefficients();
    test_golden_sequence();
    test_refinement_sequence();
    test_fuzz(fuzz);
    if (oracle) printf("oracle: Screen Sharing decoded %ld updates beside Remora, %ld with the pictures compared\n", both_decoded, both_pictures);
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    printf(oracle ? "Remora and Screen Sharing agree\n" : "all decoder tests passed\n");
    return 0;
}
