/* Remora's opt-in plaintext Apple 003.889 profile. GPL-3.0-or-later. */
#ifndef REMORA_APPLE_H
#define REMORA_APPLE_H
#include <rfb/rfbclient.h>
/* These functions belong to the authenticated worker. No callback reenters the parser. */
rfbBool rfbRemoraAppleRememberKey(rfbClient *, const unsigned char key[16]);
void rfbRemoraAppleCleanup(rfbClient *);
rfbBool rfbRemoraAppleSetup(rfbClient *);
rfbBool rfbRemoraAppleRetryBaseline(rfbClient *);
rfbBool rfbRemoraAppleEncodings(rfbClient *);
int rfbRemoraAppleMessage(rfbClient *, unsigned char type);
void rfbRemoraAppleBegin(rfbClient *);
/* -1 failure, 0 Raw handled by the existing decoder, 1 handled MVS/control. */
int rfbRemoraAppleRect(rfbClient *, const rfbFramebufferUpdateRectHeader *);
void rfbRemoraAppleRaw(rfbClient *, const rfbFramebufferUpdateRectHeader *);
rfbBool rfbRemoraAppleEnd(rfbClient *);
rfbBool rfbRemoraAppleKey(rfbClient *, uint32_t, rfbBool);
rfbBool rfbRemoraApplePointer(rfbClient *, int, int, int);
#endif
