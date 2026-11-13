/* Remora's experimental Apple 003.889 adapter. GPL-3.0-or-later.
 * Wire definitions: peetinc/noVNC-ARD d699293635083c9e0c30c8f9480993865653772a,
 * ard/ard-patch.js. The scroll record follows ard-rs protocol.rs's 0x17/54 layout.
 * The separately licensed MVS implementation is in mvs.c/h.
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
    double baselineRequestAt;
    uint32_t previousInputTime;
    uint32_t left, top, right, bottom;
    mvs_decoder *decoder;
} Apple;
static Apple *state(rfbClient *c) { return c->remoraAppleState; }
static double monotonic(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec/1e9;
}
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
    a->baselineRequestAt=monotonic()+1;
    return WriteToRFBServer(c,mode,sizeof(mode));
}
/* The initial full request can go unanswered, or produce only controls/partial
 * coverage. Keep requesting a baseline alongside the push subscription.
 * Called between complete messages, never during a rectangle decode. */
rfbBool rfbRemoraAppleRetryBaseline(rfbClient *c) {
    Apple *a=state(c);
    if(!a) return fail(c,APPLE_PROFILE);
    if(a->baseline || !a->demand) return TRUE;
    double now=monotonic();
    if(now<a->baselineRequestAt) return TRUE;
    a->baselineRequestAt=now+1;
    return SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE);
}
rfbBool rfbRemoraAppleEncodings(rfbClient *c) {
    uint8_t message[24]={2,0,0,5};
    put32(message+4,1011); put32(message+8,0); put32(message+12,1105); put32(message+16,(uint32_t)-223); put32(message+20,1101);
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
rfbBool rfbRemoraDisplayReset(rfbClient *c) {
    if(!state(c)) c->remoraAppleState=calloc(1,sizeof(Apple));
    Apple *a=state(c);
    if(!a) return fail(c,APPLE_DECODE);
    if(!a->decoder) a->decoder=mvs_create();
    if(!a->decoder) return fail(c,APPLE_DECODE);
    mvs_reset_picture(a->decoder); a->baseline=FALSE; a->dirty=FALSE;
    return TRUE;
}
rfbBool rfbRemoraDisplayReady(rfbClient *c) {
    Apple *a=state(c);
    return a && a->decoder && mvs_region_initialized(a->decoder,0,0,c->width,c->height);
}
rfbBool rfbRemoraDisplayRaw(rfbClient *c,int x,int y,int w,int h) {
    Apple *a=state(c);
    if(!a || !a->decoder) return FALSE;
    if(mvs_mark_raw(a->decoder,c->width,c->height,x,y,w,h)!=MVS_OK) return FALSE;
    a->baseline=mvs_region_initialized(a->decoder,0,0,c->width,c->height);
    return TRUE;
}
/* Both Apple's standard 3.8 and native profile may advertise DisplayInfo2. */
static rfbBool displayInfo(rfbClient *c) {
    uint8_t length[2];
    if(!ReadFromRFBServer(c,(char *)length,2)) return FALSE;
    uint32_t n=be16(length);
    if(n<20 || n>20+64*56) return fail(c,APPLE_PROFILE);
    uint8_t body[20+64*56];
    if(!ReadFromRFBServer(c,(char *)body,n)) return FALSE;
    uint32_t count=be16(body+18);
    if(!count || count>64 || n!=20+count*56 || !be16(body+6) || !be16(body+8)) return fail(c,APPLE_PROFILE);
    rfbRemoraDisplay displays[64];
    for(uint32_t i=0;i<count;i++) {
        const uint8_t *p=body+20+i*56;
        int left=(int16_t)be16(p+30), top=(int16_t)be16(p+28);
        rfbRemoraDisplay d={be32(p+16),(int16_t)be16(p+22),(int16_t)be16(p+20),
            (int16_t)be16(p+34)-left,(int16_t)be16(p+32)-top,(be32(p+36)&1)!=0};
        if(d.id==UINT32_MAX || d.width<=0 || d.height<=0 || d.width>16384 || d.height>16384 ||
           (uint64_t)d.width*d.height>67108864) return fail(c,APPLE_PROFILE);
        for(uint32_t j=0;j<i;j++) if(displays[j].id==d.id) return fail(c,APPLE_PROFILE);
        displays[i]=d;
    }
    uint32_t id=be32(body+10);
    unsigned width=be16(body+6), height=be16(body+8);
    if(width>16384 || height>16384 || (uint64_t)width*height>67108864) return fail(c,APPLE_GEOMETRY);
    if(id!=UINT32_MAX) {
        rfbBool found=FALSE;
        for(uint32_t i=0;i<count;i++) if(displays[i].id==id) found=TRUE;
        if(!found) return fail(c,APPLE_PROFILE);
    }
    rfbBool first=c->remoraDisplayCount==0;
    rfbBool geometry=c->width!=(int)width || c->height!=(int)height;
    memcpy(c->remoraDisplays,displays,count*sizeof(*displays));
    c->remoraDisplayCount=count; c->remoraDisplayID=id;
    /* DisplayInfo2 itself carries geometry, including same-size display switches. */
    if(!rfbRemoraDisplayReset(c)) return FALSE;
    if(geometry) {
        c->width=width; c->height=height;
        if(c->isUpdateRectManagedByLib) {
            c->updateRect.x=c->updateRect.y=0; c->updateRect.w=width; c->updateRect.h=height;
        }
        if(!c->MallocFrameBuffer(c)) return FALSE;
    }
    if(c->RemoraDisplays) c->RemoraDisplays(c);
    /* A display acknowledgement can stop pushed pixels until explicitly requested. */
    if(!first && !SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE)) return FALSE;
    Apple *a=state(c);
    if(!c->remoraApple889) a->demand=TRUE;
    if(!first || geometry) a->subscribed=FALSE;
    if(!rfbRemoraAppleSetDemand(c,a->demand)) return FALSE;
    return c->remoraApple889 || SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE);
}
rfbBool rfbRemoraSelectDisplay(rfbClient *c,uint32_t id) {
    for(uint32_t i=0;i<c->remoraDisplayCount;i++) if(c->remoraDisplays[i].id==id) {
        uint8_t message[8]={0x0d}; put32(message+4,id);
        return WriteToRFBServer(c,(char *)message,sizeof(message));
    }
    return FALSE;
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
    case 0x51: return displayInfo(c)?1:-1;
    default: return fail(c,APPLE_PROFILE),-1;
    }
}
void rfbRemoraAppleBegin(rfbClient *c) { state(c)->dirty=FALSE; }
/* Decoder callbacks are speculative until every rectangle in the message validates. */
static void damage(void *context,uint32_t x,uint32_t y,uint32_t w,uint32_t h) {
    Apple *a=context;
    if(!w || !h) return;
    if(!a->dirty) {
        a->left=x; a->top=y; a->right=x+w; a->bottom=y+h;
    } else {
        if(x<a->left) a->left=x;
        if(y<a->top) a->top=y;
        if(x+w>a->right) a->right=x+w;
        if(y+h>a->bottom) a->bottom=y+h;
    }
    a->dirty=TRUE;
}
int rfbRemoraAppleRect(rfbClient *c,const rfbFramebufferUpdateRectHeader *r) {
    if(r->encoding==1105) return displayInfo(c)?1:-1;
    if(r->encoding==1101) {
        uint8_t h[8];
        if(!ReadFromRFBServer(c,(char *)h,8)) return -1;
        uint32_t count=be16(h+4);
        if(count>64) return fail(c,APPLE_PROFILE),-1;
        return skip(c,count*28)?1:-1;
    }
    Apple *a=state(c);
    if(r->encoding==(uint32_t)-223 || r->encoding==(uint32_t)-308) return 0;
    if(r->encoding==0) return 0;
    if(r->encoding!=1011) {
        fail(c,APPLE_PROFILE);
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
    /* The decoder checks initialized pixels and DCT baselines for each region. */
    if (!quant && !geometry) {
        free(payload); return fail(c,APPLE_DECODE),-1;
    }
    mvs_surface surface={(uint8_t *)c->frameBuffer,c->width,c->height,(size_t)c->width*4,16,8,0};
    mvs_stats stats;
    mvs_error error=mvs_decode(a->decoder,&surface,r->r.x,r->r.y,r->r.w,r->r.h,payload,n,damage,a,&stats);
    free(payload);
    if(error!=MVS_OK) return fail(c,APPLE_DECODE),-1;
    if(!quant) {
        a->baseline=mvs_region_initialized(a->decoder,0,0,c->width,c->height);
    }
    return 1;
}
void rfbRemoraAppleRaw(rfbClient *c,const rfbFramebufferUpdateRectHeader *r) {
    damage(state(c),r->r.x,r->r.y,r->r.w,r->r.h);
    Apple *a=state(c);
    if(mvs_mark_raw(a->decoder,c->width,c->height,r->r.x,r->r.y,r->r.w,r->r.h)!=MVS_OK) fail(c,APPLE_DECODE);
    a->baseline=mvs_region_initialized(a->decoder,0,0,c->width,c->height);
}
/* AutoFBUpdate uses interval 0 to subscribe and UINT32_MAX to pause, with flags 1. */
rfbBool rfbRemoraAppleSetDemand(rfbClient *c,rfbBool enabled) {
    Apple *a=state(c);
    if(!a) return fail(c,APPLE_PROFILE);
    if(!a->baseline && enabled && !a->demand) a->baselineRequestAt=monotonic()+1;
    a->demand=enabled;
    if(a->subscribed==enabled) return TRUE;
    if(c->RemoraUpdateAllowed && !c->RemoraUpdateAllowed(c,FALSE)) return FALSE;
    uint8_t m[16]={9,0,0,1}; put32(m+4,enabled?0:UINT32_MAX);
    put16(m+12,c->width); put16(m+14,c->height);
    if(!WriteToRFBServer(c,(char *)m,sizeof(m))) return FALSE;
    a->subscribed=enabled;
    return TRUE;
}
rfbBool rfbRemoraAppleEnd(rfbClient *c) {
    Apple *a=state(c);
    if(c->remoraAppleError || !rfbRemoraAppleSetDemand(c,a->demand)) return FALSE;
    if(a->dirty) c->GotFrameBufferUpdate(c,a->left,a->top,a->right-a->left,a->bottom-a->top);
    return TRUE;
}
/* Apple's combined input format shares its elapsed-time counter across keys and pointers. */
static rfbBool sendInput(rfbClient *c,uint8_t plain[16]) {
    Apple *a=state(c);
    if(!a || !a->keyValid || c->remoraDiagnostic.phase!=RFB_REMORA_READY) return fail(c,APPLE_PROFILE);
    uint8_t wire[18]={0x10,0}; int length=0;
    struct timespec now; clock_gettime(CLOCK_MONOTONIC,&now);
    uint32_t timestamp=(uint32_t)((uint64_t)now.tv_sec*1000000+now.tv_nsec/1000);
    put32(plain+6,timestamp-a->previousInputTime);
    rfbBool ok=encrypt_aes128ecb(wire+2,&length,a->key,plain,16) && length==16;
    if(ok) ok=WriteToRFBServer(c,(char *)wire,sizeof(wire));
    if(ok) a->previousInputTime=timestamp;
    OPENSSL_cleanse(plain,16); OPENSSL_cleanse(wire,sizeof(wire));
    return ok;
}
rfbBool rfbRemoraAppleKey(rfbClient *c,uint32_t keysym,rfbBool down) {
    /* Option is Meta for ARD, preserving the source's held-key identity on both transitions. */
    if(keysym==0xffe9) keysym=0xffe7;
    if(keysym==0xffea) keysym=0xffe8;
    uint8_t plain[16]={0xff,down?1:0}; put32(plain+2,keysym);
    return sendInput(c,plain);
}
rfbBool rfbRemoraApplePointer(rfbClient *c,int x,int y,int mask) {
    /* The common source-button state stays in Remora. Only the wire mask changes. */
    uint8_t plain[16]={0};
    plain[10]=0xff; plain[11]=(uint8_t)((mask&1)|((mask&4)>>1)|((mask&2)<<1));
    put16(plain+12,x); put16(plain+14,y);
    if(!sendInput(c,plain)) return FALSE;
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
