/* Apple Screen Sharing record transport. GPL-3.0-or-later. */
#ifndef REMORA_APPLE_RECORDS_H
#define REMORA_APPLE_RECORDS_H
#include <rfb/rfbclient.h>

enum { APPLE_ENCRYPTION_REQUIRED = 14, APPLE_INVALID_RECORD = 15, APPLE_REKEY = 16 };
/* clipboardChanged reports a pasteboard change announced while waiting for the key, which the caller must fetch. */
rfbBool rfbRemoraStartRecords(rfbClient *, const uint8_t wrappingKey[16], double deadline, rfbBool *clipboardChanged);
void rfbRemoraFreeRecords(rfbClient *);
rfbBool rfbRemoraReadRecords(rfbClient *, char *, unsigned int, double deadline);
rfbBool rfbRemoraWriteRecords(rfbClient *, const char *, unsigned int);

/* LibVNCClient owns socket I/O and its ciphertext read-ahead buffer. */
rfbBool rfbRemoraReadWire(rfbClient *, char *, unsigned int, double deadline);
rfbBool rfbRemoraWriteWire(rfbClient *, const char *, unsigned int);
#endif
