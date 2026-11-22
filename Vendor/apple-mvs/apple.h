/* Remora's opt-in encrypted Apple 003.889 profile. GPL-3.0-or-later. */
#ifndef REMORA_APPLE_H
#define REMORA_APPLE_H
#include <rfb/rfbclient.h>
/* Profile errors are local numeric diagnostics, never server-controlled strings. Login unavailable: the
 * server did not offer security type 36. Identity: the server did not prove it holds the account's verifier. */
enum {
    APPLE_PROFILE = 8, APPLE_DECODE = 9, APPLE_GEOMETRY = 10, APPLE_CLIPBOARD = 17,
    APPLE_LOGIN_UNAVAILABLE = 18, APPLE_IDENTITY = 19
};
/* The SRP login of security type 36, up to the SecurityResult. It verifies the server before it stores the
 * record layer's wrapping key. */
rfbBool rfbRemoraAppleLogin(rfbClient *);
/* These functions belong to the authenticated worker. No callback reenters the parser. */
rfbBool rfbRemoraAppleRememberKey(rfbClient *, const unsigned char key[16]);
void rfbRemoraAppleCleanup(rfbClient *);
rfbBool rfbRemoraAppleSetup(rfbClient *);
rfbBool rfbRemoraAppleRetryBaseline(rfbClient *);
rfbBool rfbRemoraAppleEncodings(rfbClient *);
int rfbRemoraAppleMessage(rfbClient *, unsigned char type);
rfbBool rfbRemoraAppleClipboard(rfbClient *, const char *, int);
void rfbRemoraAppleBegin(rfbClient *);
/* -1 failure, 0 Raw handled by the existing decoder, 1 handled MVS/control. */
int rfbRemoraAppleRect(rfbClient *, const rfbFramebufferUpdateRectHeader *);
void rfbRemoraAppleRaw(rfbClient *, const rfbFramebufferUpdateRectHeader *);
rfbBool rfbRemoraAppleEnd(rfbClient *);
rfbBool rfbRemoraAppleEncrypt(rfbClient *);
rfbBool rfbRemoraApplePointer(rfbClient *, int, int, int);
#endif
