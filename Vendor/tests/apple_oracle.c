#include "apple_oracle.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <uuid/uuid.h>

#define FRAMEWORK "/System/Library/PrivateFrameworks/ScreenSharing.framework/Versions/A/ScreenSharing"

/* Session field offsets, read from the arm64e code of macOS 27.0.1 (26A434).
 * apple_oracle_load checks the ones it can. */
enum {
    S_MAGIC = 0x0,        /* 'view' */
    S_NETBUFFER = 0x10,   /* the input buffer DecodeMVSUpdate reads, 'nbuf' */
    S_FRAMEBUFFER = 0xab0,
    S_WIDTH = 0xab8,
    S_HEIGHT = 0xabc,
    S_ROW_BYTES = 0xd60,
    S_PIXEL_BYTES = 0xd64,
    S_TILES = 0xdf8,
    S_IDCT = 0xe10,       /* the transform state, allocated by the first full or quantization update */
    SESSION_BYTES = 0x1070,
};

static struct {
    void *(*RFBInitializeConnectionRef)(void);
    int (*RFBDefineCallback)(void *session, void *callback, void *context);
    int (*RFBSetLocalBitmap)(void *session, void *base, uint32_t width, uint32_t height, uint32_t row_bytes, uint32_t depth);
    int (*NetBufferAddData)(void *buffer, uint32_t length, const void *bytes);
    int (*DecodeMVSUpdate)(void *session, uint16_t rect[4]);
    void (*jpeg_idct_islow)(void *state, uint16_t **quant, const int16_t *coefficients, uint16_t *out);
    void (*Cache_Dispose)(void *session);
} apple;

static char identity[128], reason[256];
static void *idct_state;

struct apple_mvs { uint8_t *session, *pixels; };

static uint32_t field32(const uint8_t *session, size_t offset) { uint32_t v; memcpy(&v, session + offset, 4); return v; }
static void *field_pointer(const uint8_t *session, size_t offset) { void *v; memcpy(&v, session + offset, sizeof v); return v; }

/* The address of a symbol that the image defines and does not export. */
static void *lookup(const struct mach_header_64 *header, intptr_t slide, const char *name) {
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *lc = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT))
            linkedit = (const void *)lc;
    }
    if (!symtab || !linkedit) return NULL;
    const char *base = (const char *)(slide + (intptr_t)linkedit->vmaddr - (intptr_t)linkedit->fileoff);
    const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
    const char *strings = base + symtab->stroff;
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if ((symbols[i].n_type & N_STAB) || (symbols[i].n_type & N_TYPE) != N_SECT) continue;
        if (!strcmp(strings + symbols[i].n_un.n_strx, name)) return (void *)((intptr_t)symbols[i].n_value + slide);
    }
    return NULL;
}

static void screen_updated(void *session, void *context, int kind, void *rect, int length) {
    (void)session; (void)context; (void)kind; (void)rect; (void)length;
}

static apple_mvs *session_new(uint32_t width, uint32_t height) {
    apple_mvs *m = calloc(1, sizeof *m);
    m->pixels = calloc((size_t)width * height, 4);
    m->session = apple.RFBInitializeConnectionRef();
    if (!m->session || malloc_size(m->session) < SESSION_BYTES) return m;
    apple.RFBDefineCallback(m->session, (void *)screen_updated, NULL);
    apple.RFBSetLocalBitmap(m->session, m->pixels, width, height, width * 4, 32);
    return m;
}

static const char *load(void) {
#if !defined(__arm64__)
    return "its session layout is known for arm64 only";
#endif
    if (!dlopen(FRAMEWORK, RTLD_NOW)) {
        snprintf(reason, sizeof reason, "dlopen failed: %s", dlerror());
        return reason;
    }
    const struct mach_header_64 *header = NULL;
    intptr_t slide = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), FRAMEWORK)) continue;
        header = (const void *)_dyld_get_image_header(i);
        slide = _dyld_get_image_vmaddr_slide(i);
    }
    if (!header) return "dyld does not list the ScreenSharing image";

    char uuid[40] = "no LC_UUID", version[32] = "?", build[32] = "?";
    const struct load_command *lc = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize))
        if (lc->cmd == LC_UUID) uuid_unparse_upper(((const struct uuid_command *)lc)->uuid, uuid);
    size_t n = sizeof version;
    sysctlbyname("kern.osproductversion", version, &n, NULL, 0);
    n = sizeof build;
    sysctlbyname("kern.osversion", build, &n, NULL, 0);
    snprintf(identity, sizeof identity, "ScreenSharing %s, macOS %s (%s)", uuid, version, build);

    const struct { const char *name; void **slot; } wanted[] = {
        { "_RFBInitializeConnectionRef", (void **)&apple.RFBInitializeConnectionRef },
        { "_RFBDefineCallback", (void **)&apple.RFBDefineCallback },
        { "_RFBSetLocalBitmap", (void **)&apple.RFBSetLocalBitmap },
        { "_NetBufferAddData", (void **)&apple.NetBufferAddData },
        { "_DecodeMVSUpdate", (void **)&apple.DecodeMVSUpdate },
        { "_jpeg_idct_islow", (void **)&apple.jpeg_idct_islow },
        { "_Cache_Dispose", (void **)&apple.Cache_Dispose },
    };
    for (size_t i = 0; i < sizeof wanted / sizeof *wanted; i++) {
        if ((*wanted[i].slot = lookup(header, slide, wanted[i].name))) continue;
        snprintf(reason, sizeof reason, "%s has no symbol %s", identity, wanted[i].name);
        return reason;
    }

    /* A session of the known layout is 0x1070 bytes or more, starts with 'view', owns an input
     * buffer that starts with 'nbuf', and holds the bitmap it was given at the known offsets. */
    apple_mvs *probe = session_new(24, 16);
    const uint8_t *s = probe->session;
    const uint8_t *buffer = s && malloc_size(s) >= SESSION_BYTES ? field_pointer(s, S_NETBUFFER) : NULL;
    if (!buffer || field32(s, S_MAGIC) != 0x76696577 || field32(buffer, 0) != 0x6e627566 ||
        field_pointer(s, S_FRAMEBUFFER) != probe->pixels || field32(s, S_WIDTH) != 24 || field32(s, S_HEIGHT) != 16 ||
        field32(s, S_ROW_BYTES) != 96 || field32(s, S_PIXEL_BYTES) != 4 || !field_pointer(s, S_TILES)) {
        snprintf(reason, sizeof reason, "%s lays out its session differently from macOS 27.0.1", identity);
        return reason;
    }
    /* A quantization update is accepted and allocates the transform state, which is all
     * jpeg_idct_islow needs. A DC coefficient of 8 under a step of 16 then transforms to 144. */
    uint8_t tables[129] = { 2 }, flat[64];
    const int16_t coefficients[64] = { 8 };
    const uint16_t quant[64] = { 16 };
    const int status = apple_mvs_decode(probe, 0, 0, 0, 0, tables, sizeof tables);
    idct_state = field_pointer(s, S_IDCT);
    if (status || !idct_state) {
        snprintf(reason, sizeof reason, "%s answers a quantization update with status %d", identity, status);
        return reason;
    }
    apple_idct(coefficients, quant, flat);
    apple_mvs_destroy(probe);
    if (flat[0] != 144 || flat[63] != 144) {
        snprintf(reason, sizeof reason, "%s transforms a flat block to %u", identity, flat[0]);
        return reason;
    }
    return NULL;
}

const char *apple_oracle_load(void) {
    /* A framework these calls no longer fit may crash under them. Find that out in a child. */
    int status = 0;
    const pid_t child = fork();
    if (child == 0) _exit(load() ? 1 : 0);
    if (child < 0 || waitpid(child, &status, 0) != child) return "the probe process could not run";
    if (WIFSIGNALED(status)) {
        snprintf(reason, sizeof reason, "its code stopped the probe process with signal %d", WTERMSIG(status));
        return reason;
    }
    return load();
}

const char *apple_oracle_identity(void) { return identity; }

apple_mvs *apple_mvs_create(uint32_t width, uint32_t height) { return session_new(width, height); }

/* RFBDisposeConnectionRef also closes sockets and posts notifications. Free the large
 * allocations and leave the rest of the session. */
void apple_mvs_destroy(apple_mvs *m) {
    if (!m) return;
    apple.Cache_Dispose(m->session);
    free(field_pointer(m->session, S_TILES));
    free(m->pixels);
    free(m);
}

const uint8_t *apple_mvs_pixels(const apple_mvs *m) { return m->pixels; }

int apple_mvs_decode(apple_mvs *m, uint32_t x, uint32_t y, uint32_t w, uint32_t h, const uint8_t *payload, size_t length) {
    void *buffer = field_pointer(m->session, S_NETBUFFER);
    const uint8_t prefix[4] = { (uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length };
    if (apple.NetBufferAddData(buffer, 4, prefix) || apple.NetBufferAddData(buffer, (uint32_t)length, payload)) {
        fprintf(stderr, "NetBufferAddData refused %zu bytes\n", length);
        abort();
    }
    uint16_t rect[4] = { (uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h };
    return apple.DecodeMVSUpdate(m->session, rect);
}

void apple_idct(const int16_t coefficients[64], const uint16_t quant[64], uint8_t out[64]) {
    uint16_t table[64], samples[64];
    memcpy(table, quant, sizeof table);
    uint16_t *table_pointer = table;
    apple.jpeg_idct_islow(idct_state, &table_pointer, coefficients, samples);
    for (int i = 0; i < 64; i++) out[i] = (uint8_t)samples[i];
}
