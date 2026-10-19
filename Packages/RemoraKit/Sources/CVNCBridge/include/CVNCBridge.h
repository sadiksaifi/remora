#ifndef CVNCBRIDGE_H
#define CVNCBRIDGE_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
typedef struct RMVNC RMVNC;
typedef struct {
    void (*size)(void *, int, int, bool);
    void (*frame)(void *, const uint8_t *, int, int, int, int, int, int);
    void (*cursor)(void *, const uint8_t *, int, int, int, int);
    void (*clipboard)(void *, const char *, int, bool);
    bool (*credentials)(void *, bool, char **, char **);
    bool (*trust)(void *, const char *, const uint8_t *, size_t);
    /* Fill 32 bytes if this endpoint has a pin. */
    bool (*pin)(void *, uint8_t *);
} RMVNCCallbacks;
/* All calls except abort belong to one owning thread. Abort is safe while
 * connect, TLS, authentication, a prompt, or an incomplete frame is blocked. */
RMVNC *rm_vnc_create(const char *host, uint16_t port, RMVNCCallbacks callbacks, void *user);
bool rm_vnc_connect(RMVNC *);
void rm_vnc_abort(RMVNC *);
void rm_vnc_free(RMVNC *);
bool rm_vnc_step(RMVNC *);
int rm_vnc_error(RMVNC *); /* 1 DNS, 2 refused, 3 timeout, 4 auth, 5 certificate, 6 protocol */
const char *rm_vnc_security(RMVNC *);
bool rm_vnc_resize_supported(RMVNC *);
bool rm_vnc_resize(RMVNC *, uint16_t, uint16_t);
bool rm_vnc_refresh(RMVNC *);
uint32_t rm_vnc_unicode_keysym(uint32_t scalar);
bool rm_vnc_key(RMVNC *, uint32_t keysym, uint32_t qnum, bool down);
bool rm_vnc_pointer(RMVNC *, uint16_t, uint16_t, uint8_t mask);
bool rm_vnc_clipboard_utf8(RMVNC *);
bool rm_vnc_clipboard(RMVNC *, const char *, int, bool utf8);
#endif
