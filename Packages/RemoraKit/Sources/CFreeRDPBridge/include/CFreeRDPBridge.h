#ifndef REMORA_C_FREERDP_BRIDGE_H
#define REMORA_C_FREERDP_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RMRDPSession RMRDPSession;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *domain;
    const char *password; /* NULL means missing; empty is a supplied password. */
    const char *config_path;
    uint32_t width;
    uint32_t height;
    double scale_factor;
} RMRDPConfiguration;

typedef struct {
    int32_t x, y, width, height;
} RMRDPRectangle;

typedef enum {
    RMRDP_DISCONNECT_NONE,
    RMRDP_DISCONNECT_AUTHENTICATION_FAILED,
    RMRDP_DISCONNECT_CERTIFICATE_REJECTED,
    RMRDP_DISCONNECT_HOST_NOT_FOUND,
    RMRDP_DISCONNECT_CONNECTION_REFUSED,
    RMRDP_DISCONNECT_CONNECTION_TIMED_OUT,
    RMRDP_DISCONNECT_SERVER_ENDED_SESSION,
    RMRDP_DISCONNECT_PROTOCOL_ERROR,
    RMRDP_DISCONNECT_CANCELLED
} RMRDPDisconnectReason;

/* Callbacks are synchronous and may run on different background threads.
 * All callback arguments are borrowed for the duration of that call. */
typedef struct {
    void (*connected)(void *user);
    void (*disconnected)(void *user, RMRDPDisconnectReason reason, const char *message);
    void (*desktop_size)(void *user, uint32_t width, uint32_t height);
    /* BGRA32 bytes, alpha ignored. Copy pixels before returning. */
    void (*frame)(void *user, const uint8_t *pixels, uint32_t width, uint32_t height,
                  uint32_t stride, const RMRDPRectangle *rectangles, size_t count);
    /* On success supply malloc-owned strings in all three outputs; the bridge takes ownership.
     * On cancellation return false and leave outputs NULL. */
    bool (*credentials)(void *user, const char *username, const char *domain, bool rejected,
                        char **new_username, char **new_domain, char **new_password);
    /* old_fingerprint is NULL for a new certificate. true accepts AND stores the certificate. */
    bool (*trust)(void *user, const char *host, uint16_t port, const char *subject,
                  const char *issuer, const char *fingerprint, const char *old_fingerprint);
} RMRDPCallbacks;

/* Copies configuration and callbacks. Create/run/free on the owned session thread.
 * The caller must keep user alive through free. NULL means invalid configuration or allocation failure. */
RMRDPSession *rm_rdp_create(const RMRDPConfiguration *config, const RMRDPCallbacks *callbacks,
                           void *user);
/* Single-use; blocks through connection, event loop and channel cleanup. */
void rm_rdp_run(RMRDPSession *session);
/* The only cross-thread operation. Does not free; run must return before free. */
void rm_rdp_abort(RMRDPSession *session);
void rm_rdp_free(RMRDPSession *session);

#ifdef __cplusplus
}
#endif
#endif
