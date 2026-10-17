#include "reconnect.h"
#include <freerdp/error.h>

/* Deliberately stricter than client_auto_reconnect_ex: a server disconnect PDU,
 * logoff, graphics failure or authentication error is not a network drop. */
static BOOL network_failure(freerdp *instance, bool retrying) {
    if (freerdp_error_info(instance) != ERRINFO_SUCCESS)
        return FALSE;
    switch (freerdp_get_last_error(instance->context)) {
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED: /* Includes EOF/reset on the transport. */
        case FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT:
            return TRUE;
        case FREERDP_ERROR_CONNECT_FAILED:
        case FREERDP_ERROR_DNS_ERROR:
        case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
            return retrying; /* Host may remain unavailable during recovery. */
        default:
            return FALSE;
    }
}

BOOL rm_reconnect(freerdp *instance, RMInput *input, const RMRDPCallbacks *callbacks,
                  void *user, const atomic_bool *aborted) {
    if (atomic_load(aborted) || !network_failure(instance, false) ||
        !freerdp_settings_get_bool(instance->context->settings, FreeRDP_AutoReconnectionEnabled))
        return FALSE;
    unsigned delay = 1;
    for (unsigned attempt = 1; attempt <= 20 && !atomic_load(aborted); attempt++) {
        if (callbacks->reconnecting)
            callbacks->reconnecting(user, attempt);
        // The callback gates Swift input before discarding commands from the failed connection.
        rm_input_discard_pending(input);
        for (unsigned tick = 0; tick < delay * 20; tick++) {
            if (atomic_load(aborted))
                return FALSE;
            Sleep(50);
        }
        if (atomic_load(aborted))
            return FALSE;
        /* Unlike a fresh context, this keeps the auto-reconnect cookie and runs
         * FreeRDP's channel disconnect/rebind logic. GNOME Remote Login sends
         * LB_LOAD_BALANCE_INFO without a new target: FreeRDP keeps the original
         * host plus the routing token/RDSTLS settings, rather than inventing a target. */
        if (freerdp_reconnect(instance))
            return !atomic_load(aborted);
        if (!network_failure(instance, true))
            return FALSE;
        delay = delay >= 5 ? 10 : delay * 2;
    }
    return FALSE;
}
