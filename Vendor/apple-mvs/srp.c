/* Apple Screen Sharing's SRP login, RFB security type 36. GPL-3.0-or-later.
 * README.md, "Login", gives the message layouts, the derivation and their sources.
 * This is Remora's own implementation on OpenSSL. It contains no Apple code. */
#include "apple.h"
#include "records.h"
#include <openssl/bn.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The RFC 5054 4096-bit group with SHA-512. The iteration bound keeps a peer from stalling the client in PBKDF2. */
enum { GROUP = 512, HASH = 64, STRETCHED = 128, MAX_NAME = 255, MAX_MESSAGE = 4096, MAX_ITERATIONS = 2000000 };
static const uint8_t generator[GROUP] = {[GROUP - 1] = 5};
static const char options[] = "mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2";

typedef struct { uint8_t A[GROUP], M1[HASH], M2[HASH], key[16]; } Proof;
typedef struct { const void *bytes; size_t length; } Part;
typedef struct { const uint8_t *at, *end; } Reader;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void put32(uint8_t *p, uint32_t n) { p[0] = (uint8_t)(n >> 24); p[1] = (uint8_t)(n >> 16); p[2] = (uint8_t)(n >> 8); p[3] = (uint8_t)n; }

static rfbBool hash(uint8_t out[HASH], const Part *parts, size_t count) {
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    rfbBool ok = ctx && EVP_DigestInit_ex(ctx, EVP_sha512(), NULL);
    for (size_t i = 0; ok && i < count; i++) ok = EVP_DigestUpdate(ctx, parts[i].bytes, parts[i].length);
    ok = ok && EVP_DigestFinal_ex(ctx, out, NULL);
    EVP_MD_CTX_free(ctx);
    return ok;
}
#define H(out, ...) hash(out, (const Part[]){__VA_ARGS__}, sizeof((const Part[]){__VA_ARGS__}) / sizeof(Part))

/* SRP-6a as corecrypto's default variant computes it. Every group element is hashed at the group's
 * length, the identity is empty, and PBKDF2 stretches the password before it enters x. */
static rfbBool prove(const uint8_t modulus[GROUP], const uint8_t *salt, size_t saltLength, const uint8_t B[GROUP],
                     int iterations, const char *password, Proof *out) {
    uint8_t stretched[STRETCHED], secret[GROUP], K[HASH], h[3][HASH];
    BN_CTX *ctx = BN_CTX_new();
    if (!ctx) return FALSE;
    BN_CTX_start(ctx);
    BIGNUM *N = BN_CTX_get(ctx), *g = BN_CTX_get(ctx), *b = BN_CTX_get(ctx), *k = BN_CTX_get(ctx), *u = BN_CTX_get(ctx);
    BIGNUM *a = BN_CTX_get(ctx), *x = BN_CTX_get(ctx), *t = BN_CTX_get(ctx), *S = BN_CTX_get(ctx);
    rfbBool ok = S && BN_bin2bn(modulus, GROUP, N) && BN_set_word(g, 5) && BN_bin2bn(B, GROUP, b);
    if (ok) {
        BN_set_flags(a, BN_FLG_CONSTTIME);
        BN_set_flags(x, BN_FLG_CONSTTIME);
    }
    /* A = g^a */
    ok = ok && BN_priv_rand(a, 512, BN_RAND_TOP_ANY, BN_RAND_BOTTOM_ANY) && BN_mod_exp(t, g, a, N, ctx) &&
        BN_bn2binpad(t, out->A, GROUP) == GROUP;
    /* x = H(salt | H(identity | ":" | stretched password)) */
    ok = ok && PKCS5_PBKDF2_HMAC(password, (int)strlen(password), salt, (int)saltLength, iterations, EVP_sha512(),
                                 STRETCHED, stretched) &&
        H(h[0], {":", 1}, {stretched, STRETCHED}) && H(h[1], {salt, saltLength}, {h[0], HASH}) && BN_bin2bn(h[1], HASH, x);
    /* k = H(N | g), u = H(A | B) */
    ok = ok && H(h[0], {modulus, GROUP}, {generator, GROUP}) && BN_bin2bn(h[0], HASH, k) &&
        H(h[0], {out->A, GROUP}, {B, GROUP}) && BN_bin2bn(h[0], HASH, u) && !BN_is_zero(u);
    /* S = (B - k g^x)^(a + u x), K = H(S) */
    ok = ok && BN_mod_exp(t, g, x, N, ctx) && BN_mod_mul(t, t, k, N, ctx) && BN_mod_sub(t, b, t, N, ctx) &&
        BN_mul(x, x, u, ctx) && BN_add(x, x, a) && BN_mod_exp(S, t, x, N, ctx) &&
        BN_bn2binpad(S, secret, GROUP) == GROUP && H(K, {secret, GROUP});
    /* M1 = H(H(N) xor H(g) | H(identity) | salt | A | B | K) */
    ok = ok && H(h[0], {modulus, GROUP}) && H(h[1], {generator, GROUP}) && H(h[2], {"", 0});
    for (int i = 0; ok && i < HASH; i++) h[0][i] ^= h[1][i];
    ok = ok && H(out->M1, {h[0], HASH}, {h[2], HASH}, {salt, saltLength}, {out->A, GROUP}, {B, GROUP}, {K, HASH});
    /* M2 = H(A | M1 | K). The record layer's wrapping key is the head of SHA-256(K). */
    ok = ok && H(out->M2, {out->A, GROUP}, {out->M1, HASH}, {K, HASH}) && EVP_Digest(K, HASH, h[0], NULL, EVP_sha256(), NULL);
    if (ok) memcpy(out->key, h[0], sizeof(out->key));
    if (S) {
        BN_clear(a);
        BN_clear(x);
        BN_clear(t);
        BN_clear(S);
    }
    BN_CTX_end(ctx);
    BN_CTX_free(ctx);
    OPENSSL_cleanse(stretched, sizeof(stretched));
    OPENSSL_cleanse(secret, sizeof(secret));
    OPENSSL_cleanse(K, sizeof(K));
    OPENSSL_cleanse(h, sizeof(h));
    return ok;
}

static const uint8_t *take(Reader *r, size_t n) {
    if ((size_t)(r->end - r->at) < n) return NULL;
    r->at += n;
    return r->at - n;
}
/* A counted field. Octet strings carry a one-byte length. Numbers and text carry two bytes. */
static const uint8_t *field(Reader *r, unsigned prefix, size_t *n) {
    const uint8_t *length = take(r, prefix);
    if (!length) return NULL;
    *n = prefix == 1 ? length[0] : (size_t)length[0] << 8 | length[1];
    return take(r, *n);
}
/* A big-endian number, left-padded to the group's length. */
static rfbBool number(Reader *r, uint8_t out[GROUP]) {
    size_t n;
    const uint8_t *bytes = field(r, 2, &n);
    if (!bytes || n > GROUP) return FALSE;
    memset(out, 0, GROUP);
    if (n) memcpy(out + GROUP - n, bytes, n);
    return TRUE;
}
static uint8_t *put(uint8_t *p, unsigned prefix, const void *bytes, size_t n) {
    if (prefix == 2) *p++ = (uint8_t)(n >> 8);
    *p++ = (uint8_t)n;
    if (n) memcpy(p, bytes, n);
    return p + n;
}
/* Every message is [BE32 length][BE32 length - 4][fields]. */
static void frame(uint8_t *start, const uint8_t *end) {
    put32(start, (uint32_t)(end - start - 4));
    put32(start + 4, (uint32_t)(end - start - 8));
}
/* The server's comma-separated list must hold every option this client selects. */
static rfbBool selectable(const uint8_t *list, size_t length) {
    for (const char *want = options; *want;) {
        size_t n = strcspn(want, ","), at = 0;
        rfbBool found = FALSE;
        while (at < length && !found) {
            const uint8_t *comma = memchr(list + at, ',', length - at);
            size_t size = comma ? (size_t)(comma - list) - at : length - at;
            found = size == n && !memcmp(list + at, want, n);
            at += size + 1;
        }
        if (!found) return FALSE;
        want += n + (want[n] == ',');
    }
    return TRUE;
}
static rfbBool fail(rfbClient *c, int error) {
    c->remoraAppleError = error;
    rfbRemoraDiagnosticFail(c, RFB_REMORA_PROTOCOL, 0, 0);
    return FALSE;
}

rfbBool rfbRemoraAppleLogin(rfbClient *c) {
    static const uint8_t zero[GROUP];
    uint8_t message[MAX_MESSAGE], modulus[GROUP], value[GROUP], B[GROUP], header[4], nonce[16], *p;
    const uint8_t *start, *salt = NULL, *count = NULL, *text, *A, *M2;
    size_t saltLength = 0, n = 0;
    uint64_t iterations = 0;
    uint32_t outer;
    Reader r;
    Proof proof;
    rfbBool ok = FALSE, valid;
    /* RFC 5054's 4096-bit modulus is the RFC 3526 prime that OpenSSL carries. */
    BIGNUM *N = BN_get_rfc3526_prime_4096(NULL);
    rfbBool group = N && BN_bn2binpad(N, modulus, GROUP) == GROUP;
    BN_free(N);

    rfbRemoraDiagnosticBegin(c, RFB_REMORA_CREDENTIALS);
    rfbCredential *cred = c->GetCredential ? c->GetCredential(c, rfbCredentialTypeUser) : NULL;
    const char *user = cred ? cred->userCredential.username : NULL, *password = cred ? cred->userCredential.password : NULL;
    if (!user || !password || strlen(user) > MAX_NAME) {
        rfbRemoraDiagnosticFail(c, RFB_REMORA_NO_CREDENTIALS, 0, 0);
        goto out;
    }
    rfbRemoraDiagnosticComplete(c, RFB_REMORA_CREDENTIALS);

    /* An empty text, the account name, an empty text and an empty octet string. macOS reads the
     * security type and this message from one delivery, so both go out in one write. */
    rfbRemoraDiagnosticBegin(c, RFB_REMORA_ARD_PARAMETERS);
    message[0] = rfbRemoraAppleSRP;
    p = put(message + 9, 2, NULL, 0);
    p = put(p, 2, user, strlen(user));
    p = put(put(p, 2, NULL, 0), 1, NULL, 0);
    frame(message + 1, p);
    if (!WriteToRFBServer(c, (char *)message, (unsigned)(p - message)) || !ReadFromRFBServer(c, (char *)header, 4)) goto out;

    /* The challenge: a zero byte, N, g, the salt, B, the PBKDF2 iteration count and the options.
     * Only the group that macOS uses is accepted, and B must be a group element other than zero. */
    outer = be32(header);
    if (!group || outer < 4 || outer > MAX_MESSAGE) { fail(c, APPLE_PROFILE); goto out; }
    if (!ReadFromRFBServer(c, (char *)message, outer)) goto out;
    r = (Reader){message, message + outer};
    valid = (start = take(&r, 5)) && be32(start) == outer - 4 && !start[4] &&
        number(&r, value) && !memcmp(value, modulus, GROUP) && number(&r, value) && !memcmp(value, generator, GROUP) &&
        (salt = field(&r, 1, &saltLength)) && number(&r, B) && memcmp(B, zero, GROUP) && memcmp(B, modulus, GROUP) < 0 &&
        (count = take(&r, 8)) && (text = field(&r, 2, &n)) && selectable(text, n) && r.at == r.end;
    if (valid) iterations = (uint64_t)be32(count) << 32 | be32(count + 4);
    if (!iterations || iterations > MAX_ITERATIONS) { fail(c, APPLE_PROFILE); goto out; }
    c->remoraDiagnostic.ardBits = GROUP * 8;
    rfbRemoraDiagnosticComplete(c, RFB_REMORA_ARD_PARAMETERS);

    rfbRemoraDiagnosticBegin(c, RFB_REMORA_ARD_SECRET);
    ERR_clear_error();
    if (!prove(modulus, salt, saltLength, B, (int)iterations, password, &proof) || RAND_bytes(nonce, sizeof(nonce)) != 1) {
        rfbRemoraDiagnosticFail(c, RFB_REMORA_CRYPTO, 0, ERR_peek_last_error());
        goto out;
    }
    rfbRemoraDiagnosticComplete(c, RFB_REMORA_ARD_SECRET);

    /* The answer: A without leading zeros, M1, the selected options and an unused 16-byte nonce. */
    rfbRemoraDiagnosticBegin(c, RFB_REMORA_ARD_WRITE);
    for (A = proof.A, n = GROUP; n > 1 && !*A; A++) n--;
    p = put(message + 8, 2, A, n);
    p = put(p, 1, proof.M1, HASH);
    p = put(p, 2, options, sizeof(options) - 1);
    p = put(p, 1, nonce, sizeof(nonce));
    frame(message, p);
    if (!WriteToRFBServer(c, (char *)message, (unsigned)(p - message))) goto out;
    rfbRemoraDiagnosticComplete(c, RFB_REMORA_ARD_WRITE);

    /* macOS answers a wrong proof with a bare SecurityResult. It delays each rejection longer than
     * the last, past 10 seconds by the third, so this read waits up to 30 seconds. */
    rfbRemoraDiagnosticBegin(c, RFB_REMORA_AUTH_RESULT);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (!rfbRemoraReadWire(c, (char *)header, 4, now.tv_sec + now.tv_nsec / 1e9 + 30)) goto out;
    outer = be32(header);
    if (outer == rfbVncAuthFailed || outer == rfbVncAuthTooMany) {
        c->remoraAuthFailed = TRUE;
        rfbRemoraDiagnosticFail(c, RFB_REMORA_AUTH_REJECTED, 0, 0);
        goto out;
    }
    /* Only a peer that holds this account's verifier can compute M2. Nothing else continues the login. */
    if (outer < 4 || outer > MAX_MESSAGE) { fail(c, APPLE_IDENTITY); goto out; }
    if (!ReadFromRFBServer(c, (char *)message, outer)) goto out;
    r = (Reader){message, message + outer};
    /* M2, the server's IV, a session ID and a TTL, and nothing after them. */
    if (!(start = take(&r, 4)) || be32(start) != outer - 4 || !(M2 = field(&r, 1, &n)) || n != HASH ||
        CRYPTO_memcmp(M2, proof.M2, HASH) || !field(&r, 1, &n) || !field(&r, 2, &n) || !take(&r, 4) || r.at != r.end) {
        fail(c, APPLE_IDENTITY);
        goto out;
    }
    ok = rfbRemoraAppleRememberKey(c, proof.key);

out:
    OPENSSL_cleanse(&proof, sizeof(proof));
    if (cred) {
        if (cred->userCredential.password) OPENSSL_cleanse(cred->userCredential.password, strlen(cred->userCredential.password));
        free(cred->userCredential.username);
        free(cred->userCredential.password);
        free(cred);
    }
    return ok;
}
