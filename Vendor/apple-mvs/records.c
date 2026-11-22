/* Apple Screen Sharing record transport. GPL-3.0-or-later. */
#include "records.h"
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <string.h>

enum { MAX_CIPHER = 65520, DIGEST = 20, MAX_BODY = MAX_CIPHER - 2 - DIGEST };

typedef struct {
    EVP_CIPHER_CTX *cipher;
    uint32_t sequence;
    /* Four scratch bytes prefix the length, body and filler for the digest. */
    uint8_t buffer[4 + MAX_CIPHER];
} Direction;

struct rfbAppleRecords {
    Direction rx, tx;
    unsigned offset, available;
};

static unsigned get16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }
static uint32_t get32(const uint8_t *p) { return (uint32_t)get16(p) << 16 | get16(p + 2); }
static void set16(uint8_t *p, unsigned n) { p[0] = (uint8_t)(n >> 8); p[1] = (uint8_t)n; }

void rfbRemoraFreeRecords(rfbClient *c) {
    struct rfbAppleRecords *r = c->remoraRecords;
    if (!r) return;
    EVP_CIPHER_CTX_free(r->rx.cipher);
    EVP_CIPHER_CTX_free(r->tx.cipher);
    OPENSSL_clear_free(r, sizeof(*r));
    c->remoraRecords = NULL;
}

static EVP_CIPHER_CTX *cipher(const EVP_CIPHER *algorithm, const uint8_t *key, const uint8_t *iv, int encrypt) {
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (ctx && EVP_CipherInit_ex(ctx, algorithm, NULL, key, iv, encrypt) && EVP_CIPHER_CTX_set_padding(ctx, 0))
        return ctx;
    EVP_CIPHER_CTX_free(ctx);
    return NULL;
}

/* CBC contexts persist between records, so EVP carries the last block forward. */
static rfbBool cryptBlocks(EVP_CIPHER_CTX *ctx, uint8_t *bytes, int length) {
    int written;
    return ctx && EVP_CipherUpdate(ctx, bytes, &written, bytes, length) && written == length;
}

static rfbBool readKeyUpdate(rfbClient *c, uint8_t material[32], double deadline, rfbBool *clipboardChanged) {
    uint8_t h[16];
    for (;;) {
        if (!rfbRemoraReadWire(c, (char *)h, 1, deadline)) return FALSE;
        switch (h[0]) {
        case 2: case 4: case 7: break; /* Bell, ARDAck, NOP */
        case 0x14: { /* MiscStatus. No application writes until activation. */
            if (!rfbRemoraReadWire(c, (char *)h, 3, deadline)) return FALSE;
            unsigned n = get16(h + 1);
            char discard[1024];
            if (n >= 4) {
                /* Command 2 announces a pasteboard change. */
                if (!rfbRemoraReadWire(c, discard, 4, deadline)) return FALSE;
                if (get16((uint8_t *)discard) == 1 && get16((uint8_t *)discard + 2) == 2) *clipboardChanged = TRUE;
                n -= 4;
            }
            while (n) {
                unsigned chunk = n < sizeof(discard) ? n : sizeof(discard);
                if (!rfbRemoraReadWire(c, discard, chunk, deadline)) return FALSE;
                n -= chunk;
            }
            break;
        }
        case 0:
            if (!rfbRemoraReadWire(c, (char *)h, 3, deadline)) return FALSE;
            if (!get16(h + 1)) break;
            if (get16(h + 1) != 1 || !rfbRemoraReadWire(c, (char *)h, 16, deadline)) return FALSE;
            /* Rectangle geometry, encoding 1103, generation 1, then the two wrapped blocks. */
            if (get32(h + 8) != 1103 || get32(h + 12) != 1) return FALSE;
            return rfbRemoraReadWire(c, (char *)material, 32, deadline);
        default: return FALSE;
        }
    }
}

rfbBool rfbRemoraStartRecords(rfbClient *c, const uint8_t wrappingKey[16], double deadline, rfbBool *clipboardChanged) {
    static const char controls[] = {
        0x12, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0, 1, /* Request AES session keys. */
        0x12, 0, 0, 2, 0, 1, 0, 0              /* Activate. Last clear client write. */
    };
    uint8_t material[32];
    EVP_CIPHER_CTX *unwrap = cipher(EVP_aes_128_ecb(), wrappingKey, NULL, 0);
    struct rfbAppleRecords *r = OPENSSL_zalloc(sizeof(*r));
    rfbBool ok = r && unwrap && rfbRemoraWriteWire(c, controls, sizeof(controls)) &&
        readKeyUpdate(c, material, deadline, clipboardChanged) && cryptBlocks(unwrap, material, sizeof(material));
    if (ok) {
        r->rx.cipher = cipher(EVP_aes_128_cbc(), material, material + 16, 0);
        r->tx.cipher = cipher(EVP_aes_128_cbc(), material, material + 16, 1);
        ok = r->rx.cipher && r->tx.cipher;
    }
    EVP_CIPHER_CTX_free(unwrap);
    OPENSSL_cleanse(material, sizeof(material));
    c->remoraRecords = r;
    if (!ok) {
        c->remoraAppleError = APPLE_ENCRYPTION_REQUIRED;
        rfbRemoraFreeRecords(c);
    }
    return ok;
}

rfbBool rfbRemoraRecordPending(rfbClient *c) {
    return c->remoraRecords && c->remoraRecords->available;
}

static unsigned cipherLength(unsigned n) { return (2 + n + DIGEST + 15) & ~15u; }

static rfbBool digest(Direction *d, unsigned length, uint8_t out[DIGEST]) {
    uint32_t seq = d->sequence;
    d->buffer[0] = (uint8_t)(seq >> 24);
    d->buffer[1] = (uint8_t)(seq >> 16);
    d->buffer[2] = (uint8_t)(seq >> 8);
    d->buffer[3] = (uint8_t)seq;
    d->sequence = (uint32_t)((uint64_t)seq + 1);
    return EVP_Digest(d->buffer, 4 + length - DIGEST, out, NULL, EVP_sha1(), NULL);
}

static rfbBool receive(rfbClient *c, double deadline) {
    struct rfbAppleRecords *r = c->remoraRecords;
    Direction *d = &r->rx;
    uint8_t header[2], expected[DIGEST], *body = d->buffer + 4;
    /* EOF between records is an ordinary disconnect. EOF inside a record is truncation. */
    if (!rfbRemoraReadWire(c, (char *)header, 1, deadline)) return FALSE;
    unsigned length = rfbRemoraReadWire(c, (char *)header + 1, 1, deadline) ? get16(header) : 0;
    if (length < 32 || length > MAX_CIPHER || length % 16 ||
        !rfbRemoraReadWire(c, (char *)body, length, deadline) || !cryptBlocks(d->cipher, body, length) ||
        !digest(d, length, expected) || CRYPTO_memcmp(expected, body + length - DIGEST, DIGEST) ||
        cipherLength(get16(body)) != length) {
        if (!c->remoraAppleError) c->remoraAppleError = APPLE_INVALID_RECORD;
        rfbRemoraFreeRecords(c);
        return FALSE;
    }
    r->offset = 6;
    r->available = get16(body);
    return TRUE;
}

rfbBool rfbRemoraReadRecords(rfbClient *c, char *out, unsigned n, double deadline) {
    struct rfbAppleRecords *r = c->remoraRecords;
    if (!r->rx.cipher) return FALSE;
    while (n) {
        if (!r->available && !receive(c, deadline)) return FALSE;
        unsigned count = n < r->available ? n : r->available;
        memcpy(out, r->rx.buffer + r->offset, count);
        r->offset += count;
        r->available -= count;
        out += count;
        n -= count;
    }
    return TRUE;
}

rfbBool rfbRemoraWriteRecords(rfbClient *c, const char *bytes, unsigned n) {
    Direction *d = &c->remoraRecords->tx;
    if (!d->cipher) return FALSE;
    uint8_t *body = d->buffer + 4;
    while (n) {
        unsigned count = n < MAX_BODY ? n : MAX_BODY;
        unsigned length = cipherLength(count);
        set16(body, count);
        memcpy(body + 2, bytes, count);
        memset(body + 2 + count, 0, length - DIGEST - 2 - count);
        if (!digest(d, length, body + length - DIGEST) || !cryptBlocks(d->cipher, body, length)) {
            c->remoraAppleError = APPLE_INVALID_RECORD;
            break;
        }
        set16(body - 2, length);
        if (!rfbRemoraWriteWire(c, (char *)body - 2, length + 2)) break;
        bytes += count;
        n -= count;
    }
    if (!n) return TRUE;
    /* Input service can write during a socket read. Keep the receive buffer alive
     * until it unwinds, and prevent retries on a partially written CBC stream. */
    EVP_CIPHER_CTX_free(c->remoraRecords->rx.cipher);
    EVP_CIPHER_CTX_free(d->cipher);
    OPENSSL_cleanse(c->remoraRecords, sizeof(*c->remoraRecords));
    return FALSE;
}
