#ifndef CVNCBRIDGE_H
#define CVNCBRIDGE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <rfb/rfbclient.h>
typedef struct RMVNC RMVNC;
/* Fixed numeric handshake summary. Only the owning worker reads this record. */
typedef struct {
    uint32_t phase, lastSuccess, failure;
    int framebufferWidth, framebufferHeight;
    int systemError;
    uint64_t opensslError, elapsedMS;
    uint32_t serverMajor, serverMinor, negotiatedMajor, negotiatedMinor;
    uint32_t offeredCount, offered[32], selected;
    uint32_t subofferedCount, suboffered[32], subtype, ardBits;
    bool cancelled;
} RMVNCDiagnostic;
/* Private native runtime snapshot, read by the owning worker before cleanup. */
typedef struct {
    uint32_t stage, failure, operation;
    int systemError, sslError;
    uint64_t opensslError, elapsedMS;
    int32_t messageType, rectIndex;
    uint32_t rectCount, x, y, width, height;
    int64_t encoding;
    int framebufferWidth, framebufferHeight;
    uint32_t callbacks;
    bool cancelled;
} RMVNCRuntimeDiagnostic;
typedef struct {
    uint32_t id;
    int x, y, width, height;
    bool main;
} RMVNCDisplay;
typedef struct {
    /* Selected is a fully published picture; pending is an admitted request. */
    void (*displays)(void *, const RMVNCDisplay *, uint32_t, uint32_t selected, bool ready, uint32_t pending, bool switching);
    void (*displayFailure)(void *, uint32_t id, int reason); /* 1 unavailable, 2 timed out */
    void (*size)(void *, int, int, bool);
    void (*frame)(void *, const uint8_t *, int, int, int, int, int, int);
    void (*cursor)(void *, const uint8_t *, int, int, int, int);
    /* Counted text bytes. NULL indicates a pasteboard without supported text, and NULL with -1 a remote
     * change whose text has not arrived. */
    void (*clipboard)(void *, const char *, int, bool utf8);
    void (*clipboardItem)(void *, const rfbRemoraClipboardFlavor *, int);
    bool (*credentials)(void *, bool, char **, char **);
    bool (*trust)(void *, const char *, const uint8_t *, size_t);
    /* Fill 32 bytes if this endpoint has a pin. */
    bool (*pin)(void *, uint8_t *);
    bool (*serviceInput)(void *);
} RMVNCCallbacks;
/* All calls except abort and set_input_pending belong to one owning thread. Abort is safe while
 * connect, TLS, authentication, a prompt, or an incomplete frame is blocked. */
RMVNC *rm_vnc_create(const char *host, uint16_t port, bool apple, RMVNCCallbacks callbacks, void *user);
bool rm_vnc_connect(RMVNC *);
void rm_vnc_abort(RMVNC *);
/* Atomic admission hint, safe while holding the Swift admission lock. */
void rm_vnc_set_input_pending(RMVNC *, bool);
/* Worker-only; called after authenticated connected state is published. */
void rm_vnc_enable_input_service(RMVNC *);
void rm_vnc_free(RMVNC *);
/* Worker-only, before free. Empty when no failed TCP endpoint was retained. */
const char *rm_vnc_failure_address(RMVNC *);
bool rm_vnc_step(RMVNC *);
RMVNCDiagnostic rm_vnc_diagnostic(RMVNC *);
RMVNCRuntimeDiagnostic rm_vnc_runtime_diagnostic(RMVNC *);
int rm_vnc_error(RMVNC *); /* 1 DNS, 2 refused, 3 timeout, 4 auth, 5 certificate, 6 protocol, 7 unsupported size,
 * 8 unsupported Apple profile, 9 Apple decode failure, 10 unsupported Apple geometry,
 * 11 Apple ServerInit withheld after accepted authentication (one fresh context may retry),
 * 12 reported generic multi-display layout without display selection, 13 Local Network policy denied DNS resolution,
 * 14 Apple encryption negotiation failed, 15 invalid encrypted record, 16 unsupported encryption key change,
 * 17 malformed or oversized Apple clipboard archive */
const char *rm_vnc_security(RMVNC *);
bool rm_vnc_resize_supported(RMVNC *);
bool rm_vnc_resize(RMVNC *, uint16_t, uint16_t);
bool rm_vnc_refresh(RMVNC *);
bool rm_vnc_set_display_demand(RMVNC *, bool);
/* Worker-only. No combined-desktop selection is admitted. */
bool rm_vnc_select_display(RMVNC *, uint32_t);
bool rm_vnc_display_selection_required(RMVNC *);
uint32_t rm_vnc_unicode_keysym(uint32_t scalar);
bool rm_vnc_key(RMVNC *, uint32_t keysym, uint32_t qnum, bool down);
bool rm_vnc_pointer(RMVNC *, uint16_t, uint16_t, uint8_t mask);
int rm_vnc_clipboard_item(RMVNC *, const rfbRemoraClipboardFlavor *, unsigned count);
bool rm_vnc_clipboard_utf8(RMVNC *);
bool rm_vnc_clipboard(RMVNC *, const char *, int, bool utf8);
#endif
