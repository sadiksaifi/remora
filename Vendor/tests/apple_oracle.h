/*
 * Screen Sharing's own MVS (encoding 1011) decoder, called in this process.
 *
 * Loads /System/Library/PrivateFrameworks/ScreenSharing.framework and calls
 * its unexported decoder functions at addresses resolved from the image's
 * symbol table at run time. Nothing is copied out of the framework.
 * Interoperability test use only.
 */
#ifndef REMORA_APPLE_ORACLE_H
#define REMORA_APPLE_ORACLE_H

#include <stddef.h>
#include <stdint.h>

/* Loads the framework, resolves the symbols, and checks the session layout
 * and two calls, first in a child process. Returns NULL when the decoder can
 * be called, or the reason it cannot. */
const char *apple_oracle_load(void);
/* "ScreenSharing <LC_UUID>, macOS <version> (<build>)", once the image is found. */
const char *apple_oracle_identity(void);

typedef struct apple_mvs apple_mvs;

/* A viewer session with a zeroed width x height bitmap of host-order uint32
 * 0xXXRRGGBB pixels in rows of 4 * width bytes. The X byte is not picture. */
apple_mvs *apple_mvs_create(uint32_t width, uint32_t height);
void apple_mvs_destroy(apple_mvs *);
const uint8_t *apple_mvs_pixels(const apple_mvs *);

/* Hands [BE32 length][payload] to the session and calls DecodeMVSUpdate on
 * the rect. Returns its status: 0, or an error such as -201. */
int apple_mvs_decode(apple_mvs *, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                     const uint8_t *payload, size_t length);

/* jpeg_idct_islow on 64 quantized coefficients and their quantization table,
 * both in natural order. */
void apple_idct(const int16_t coefficients[64], const uint16_t quant[64], uint8_t out[64]);

#endif
