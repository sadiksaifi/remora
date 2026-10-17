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

static bool redirected(freerdp *instance) {
    const rdpSettings *settings = instance->context->settings;
    return freerdp_settings_get_uint32(settings, FreeRDP_RedirectionFlags) != 0 ||
           freerdp_settings_get_bool(settings, FreeRDP_RdstlsSecurity);
}

static bool handover_authentication_failed(freerdp *instance) {
    if (!redirected(instance))
        return false;
    switch (freerdp_get_last_error(instance->context)) {
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
            return true;
        default:
            return false;
    }
}

BOOL rm_reconnect(freerdp *instance, RMInput *input, const RMRDPCallbacks *callbacks,
                  void *user, const atomic_bool *aborted) {
    if (atomic_load(aborted) || !network_failure(instance, false) ||
        !freerdp_settings_get_bool(instance->context->settings, FreeRDP_AutoReconnectionEnabled))
        return FALSE;
    bool fresh = redirected(instance);
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
        BOOL connected;
        if (fresh) {
            /* GNOME Remote Login's RDSTLS handover credentials are one-use.
             * Restore FreeRDP's pre-connect backup: original host/port and
             * persisted RDP credentials, without redirection state or cookies.
             * Full disconnect/connect also tears down and reloads GDI/channels;
             * the owning session, window and renderer remain alive. */
            if (!freerdp_disconnect(instance) || !freerdp_context_reset(instance) ||
                atomic_load(aborted))
                return FALSE;
            connected = freerdp_connect(instance);
        } else {
            connected = freerdp_reconnect(instance);
        }
        if (connected)
            return !atomic_load(aborted);
        if (!network_failure(instance, true) && !handover_authentication_failed(instance))
            return FALSE;
        fresh = fresh || redirected(instance);
        delay = delay >= 5 ? 10 : delay * 2;
    }
    return FALSE;
}
