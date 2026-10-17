#ifndef REMORA_CLIPBOARD_H
#define REMORA_CLIPBOARD_H
#include "CFreeRDPBridge.h"
#define WITH_OPAQUE_SETTINGS
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#include <freerdp/client.h>
#include <winpr/synch.h>
#pragma clang diagnostic pop

typedef struct RMClipboard RMClipboard;
RMClipboard *rm_clipboard_new(const RMRDPCallbacks *callbacks, void *user);
void rm_clipboard_free(RMClipboard *clipboard);
HANDLE rm_clipboard_event(RMClipboard *clipboard);
BOOL rm_clipboard_drain(RMClipboard *clipboard);
void rm_clipboard_channel_connected(void *context, const ChannelConnectedEventArgs *event);
void rm_clipboard_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *event);
RMClipboard *rm_rdp_clipboard(RMRDPSession *session);
#endif
