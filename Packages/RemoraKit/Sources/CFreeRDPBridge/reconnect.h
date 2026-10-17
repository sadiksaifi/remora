#ifndef REMORA_RECONNECT_H
#define REMORA_RECONNECT_H
#include "input.h"
#include <stdatomic.h>

/* Runs on the session thread; redirected sessions restart at the original host,
 * while other sessions retain FreeRDP's auto-reconnect cookie. */
BOOL rm_reconnect(freerdp *instance, RMInput *input, const RMRDPCallbacks *callbacks,
                  void *user, const atomic_bool *aborted);
#endif
