#ifndef REMORA_INPUT_H
#define REMORA_INPUT_H
#include "CFreeRDPBridge.h"
#define WITH_OPAQUE_SETTINGS
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/freerdp.h>
#include <winpr/synch.h>
#pragma clang diagnostic pop

typedef struct RMInput RMInput;
RMInput *rm_input_new(rdpContext *context, const RMRDPCallbacks *callbacks, void *user, bool iso_keyboard);
void rm_input_free(RMInput *input);
HANDLE rm_input_event(RMInput *input);
BOOL rm_input_drain(RMInput *input);
BOOL rm_input_release_all(RMInput *input);
void rm_input_discard_pending(RMInput *input);
void rm_input_register_pointer(RMInput *input);
/* Internal accessor; the opaque session owns input through all channel cleanup. */
RMInput *rm_rdp_input(RMRDPSession *session);
#endif
