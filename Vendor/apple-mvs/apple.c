/* Remora's experimental Apple 003.889 adapter. GPL-3.0-or-later.
 * Wire definitions: peetinc/noVNC-ARD d699293635083c9e0c30c8f9480993865653772a,
 * ard/ard-patch.js. The scroll record follows ard-rs protocol.rs's 0x17/54 layout.
 * The separately licensed, byte-identical MVS implementation is in mvs.c/h.
 */
#include "apple.h"
#include "mvs.h"
#include "crypto.h"
#include <openssl/crypto.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Profile errors are local numeric diagnostics, never server-controlled strings. */
enum { APPLE_PROFILE = 8, APPLE_DECODE = 9, APPLE_GEOMETRY = 10 };
typedef struct {
    uint8_t key[16];
    rfbBool keyValid, baseline, dirty, demand, subscribed;
    mvs_decoder *decoder;
} Apple;
static Apple *state(rfbClient *c) { return c->remoraAppleState; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)((unsigned)p[0]<<8|p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3]; }
static void put16(uint8_t *p, uint16_t n) { p[0]=(uint8_t)(n>>8); p[1]=(uint8_t)n; }
static void put32(uint8_t *p, uint32_t n) { p[0]=(uint8_t)(n>>24); p[1]=(uint8_t)(n>>16); p[2]=(uint8_t)(n>>8); p[3]=(uint8_t)n; }
static rfbBool fail(rfbClient *c, int error) {
    if (!c->remoraAppleError) c->remoraAppleError=error;
    return FALSE;
}
rfbBool rfbRemoraAppleRememberKey(rfbClient *c, const uint8_t key[16]) {
    if (!c->remoraApple889) return TRUE;
    if (!state(c)) c->remoraAppleState=calloc(1,sizeof(Apple));
    Apple *a=state(c);
    if (!a) return fail(c,APPLE_PROFILE);
    memcpy(a->key,key,16); a->keyValid=TRUE; a->demand=TRUE;
    return TRUE;
}
void rfbRemoraAppleCleanup(rfbClient *c) {
    Apple *a=state(c);
    if (!a) return;
    mvs_destroy(a->decoder);
    OPENSSL_cleanse(a,sizeof(*a)); free(a); c->remoraAppleState=NULL;
}
rfbBool rfbRemoraAppleSetup(rfbClient *c) {
    Apple *a=state(c);
    const uint8_t *n=(const uint8_t *)c->desktopName;
    if (!a || !a->keyValid || c->authScheme!=30 || !n || c->si.nameLength<22 || n[0]!=0 ||
        (be32(n+2)&4) || c->format.bitsPerPixel!=32 || c->format.bigEndian ||
        c->format.redShift!=16 || c->format.greenShift!=8 || c->format.blueShift!=0)
        return fail(c,APPLE_PROFILE);
    a->decoder=mvs_create();
    if (!a->decoder) return fail(c,APPLE_DECODE);
    /* Control mode. No session selection, session-record encryption, media or clipboard. */
    const char mode[4]={0x0a,0,0,1};
    return WriteToRFBServer(c,mode,sizeof(mode));
}
rfbBool rfbRemoraAppleEncodings(rfbClient *c) {
    uint8_t message[12]={2,0,0,2};
    put32(message+4,1011); put32(message+8,0);
    return WriteToRFBServer(c,(char *)message,sizeof(message));
}
static rfbBool skip(rfbClient *c,uint32_t n) {
    char buffer[4096];
    if(n>1024*1024) return fail(c,APPLE_PROFILE);
    while(n) {
        unsigned chunk=n<sizeof(buffer)?n:sizeof(buffer);
        if(!ReadFromRFBServer(c,buffer,chunk)) return FALSE;
        n-=chunk;
    }
    return TRUE;
}
int rfbRemoraAppleMessage(rfbClient *c,uint8_t type) {
    uint8_t h[15]; uint32_t n;
    switch(type) {
    case 0: case 2: return 0;
    case 4: case 7: return 1; /* ARDAck and NOP are one-byte messages. */
    case 3:
        if(!ReadFromRFBServer(c,(char *)h,7)) return -1;
        n=be32(h+3); if(n&0x80000000u) n=0u-n;
        return skip(c,n)?1:-1;
    case 0x1f: /* Apple pasteboard: format/reserved/session/uncompressed/compressed sizes. */
        if(!ReadFromRFBServer(c,(char *)h,15)) return -1;
        return skip(c,be32(h+11))?1:-1;
    case 0x14: /* StateChange: pad, BE16 body length, body. */
        if(!ReadFromRFBServer(c,(char *)h,3)) return -1;
        n=be16(h+1);
        if(n<4) return fail(c,APPLE_PROFILE),-1;
        return skip(c,n)?1:-1;
    case 0x51: /* DisplayInfo2 message: BE16 body length. No geometry changes supported. */
        if(!ReadFromRFBServer(c,(char *)h,2)) return -1;
        return skip(c,be16(h))?1:-1;
    default: return fail(c,APPLE_PROFILE),-1;
    }
}
void rfbRemoraAppleBegin(rfbClient *c) { state(c)->dirty=FALSE; }
int rfbRemoraAppleRect(rfbClient *c,const rfbFramebufferUpdateRectHeader *r) {
    Apple *a=state(c);
    if(r->encoding==0) return 0;
    if(r->encoding!=1011) {
        fail(c,(r->encoding==(uint32_t)-223 || r->encoding==(uint32_t)-308)?APPLE_GEOMETRY:APPLE_PROFILE);
        return -1;
    }
    uint8_t header[4];
    if(!ReadFromRFBServer(c,(char *)header,4)) return -1;
    uint32_t n=be32(header);
    uint64_t limit=(uint64_t)r->r.w*r->r.h*4+65536;
    if(n==0 || n>64u*1024*1024 || n>limit) return fail(c,APPLE_DECODE),-1;
    uint8_t *payload=malloc(n);
    if(!payload) return fail(c,APPLE_DECODE),-1;
    if(!ReadFromRFBServer(c,(char *)payload,n)) { free(payload); return -1; }
    rfbBool quant=payload[0]==2;
    rfbBool geometry= r->r.w && r->r.h && r->r.x%8==0 && r->r.y%8==0 &&
        (uint32_t)r->r.x+r->r.w<=(uint32_t)c->width && (uint32_t)r->r.y+r->r.h<=(uint32_t)c->height &&
        (r->r.w%8==0 || r->r.x+r->r.w==c->width) && (r->r.h%8==0 || r->r.y+r->r.h==c->height);
    /* A partial frame may reference untouched tiles. Require an established complete baseline. */
    if ((!quant && !geometry) || (payload[0]==1 && !a->baseline)) {
        free(payload); return fail(c,APPLE_DECODE),-1;
    }
    mvs_surface surface={(uint8_t *)c->frameBuffer,c->width,c->height,(size_t)c->width*4,16,8,0};
    mvs_stats stats;
    mvs_error error=mvs_decode(a->decoder,&surface,r->r.x,r->r.y,r->r.w,r->r.h,payload,n,NULL,NULL,&stats);
    free(payload);
    if(error!=MVS_OK) return fail(c,APPLE_DECODE),-1;
    if(!quant) {
        a->dirty=TRUE;
        if(stats.kind==MVS_KIND_FULL && r->r.x==0 && r->r.y==0 && r->r.w==c->width && r->r.h==c->height)
            a->baseline=TRUE;
    }
    return 1;
}
void rfbRemoraAppleRaw(rfbClient *c,const rfbFramebufferUpdateRectHeader *r) {
    state(c)->dirty=TRUE;
    if(r->r.x==0 && r->r.y==0 && r->r.w==c->width && r->r.h==c->height) state(c)->baseline=TRUE;
}
/* Subscription is a source-defined zero-interval full-region 0x09, not standard ContinuousUpdates. */
rfbBool rfbRemoraAppleSetDemand(rfbClient *c,rfbBool enabled) {
    Apple *a=state(c);
    if(!a) return fail(c,APPLE_PROFILE);
    a->demand=enabled;
    if(!a->baseline || a->subscribed==enabled) return TRUE;
    if(c->RemoraUpdateAllowed && !c->RemoraUpdateAllowed(c,FALSE)) return FALSE;
    uint8_t m[16]={9,0}; put16(m+2,enabled?1:0);
    put16(m+12,c->width); put16(m+14,c->height);
    if(!WriteToRFBServer(c,(char *)m,sizeof(m))) return FALSE;
    a->subscribed=enabled;
    return TRUE;
}
rfbBool rfbRemoraAppleEnd(rfbClient *c) {
    Apple *a=state(c);
    if(!rfbRemoraAppleSetDemand(c,a->demand)) return FALSE;
    if(a->dirty) c->GotFrameBufferUpdate(c,0,0,c->width,c->height);
    return TRUE;
}
rfbBool rfbRemoraAppleKey(rfbClient *c,uint32_t keysym,rfbBool down) {
    Apple *a=state(c);
    if(!a || !a->keyValid || c->remoraDiagnostic.phase!=RFB_REMORA_READY) return fail(c,APPLE_PROFILE);
    /* Option is Meta for ARD, preserving the source's held-key identity on both transitions. */
    if(keysym==0xffe9) keysym=0xffe7;
    if(keysym==0xffea) keysym=0xffe8;
    uint8_t plain[16]={0xff,down?1:0},wire[18]={0x10,0}; int length=0;
    struct timespec now; clock_gettime(CLOCK_MONOTONIC,&now);
    put32(plain+2,keysym); put32(plain+6,(uint32_t)((uint64_t)now.tv_sec*1000000+now.tv_nsec/1000));
    rfbBool ok=encrypt_aes128ecb(wire+2,&length,a->key,plain,sizeof(plain)) && length==16;
    if(ok) ok=WriteToRFBServer(c,(char *)wire,sizeof(wire));
    OPENSSL_cleanse(plain,sizeof(plain)); OPENSSL_cleanse(wire,sizeof(wire));
    return ok;
}
rfbBool rfbRemoraApplePointer(rfbClient *c,int x,int y,int mask) {
    if(!state(c) || !state(c)->keyValid || c->remoraDiagnostic.phase!=RFB_REMORA_READY) return fail(c,APPLE_PROFILE);
    /* The common source-button state stays in Remora. Only the wire mask changes. */
    uint8_t p[6]={5,(uint8_t)((mask&1)|((mask&4)>>1)|((mask&2)<<1))};
    put16(p+2,x); put16(p+4,y);
    if(!WriteToRFBServer(c,(char *)p,sizeof(p))) return FALSE;
    /* Native horizontal deltas are positive toward RFB button 0x20 (left). */
    int dx=(mask&64)?-1:(mask&32)?1:0;
    int dy=(mask&8)?1:(mask&16)?-1:0;
    if(!dx && !dy) return TRUE;
    /* Line, fixed-point and point deltas use the source's discrete-line representation. */
    uint8_t m[58]={0x17,0,0,54,0,1,0,11};
    put16(m+8,(uint16_t)dx); put16(m+10,(uint16_t)dy);
    put32(m+14,(uint32_t)(dx*65536)); put32(m+18,(uint32_t)(dy*65536));
    put32(m+26,(uint32_t)dx); put32(m+30,(uint32_t)dy); put32(m+46,1);
    put16(m+54,x); put16(m+56,y);
    return WriteToRFBServer(c,(char *)m,sizeof(m));
}
