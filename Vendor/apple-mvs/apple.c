/* Remora's experimental Apple 003.889 adapter. GPL-3.0-or-later.
 * Wire definitions: peetinc/noVNC-ARD d699293635083c9e0c30c8f9480993865653772a,
 * ard/ard-patch.js. The scroll record follows ard-rs protocol.rs's 0x17/54 layout.
 * The separately licensed MVS implementation is in mvs.c/h.
 */
#include "apple.h"
#include "mvs.h"
#include "records.h"
#include <openssl/crypto.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

/* Profile errors are local numeric diagnostics, never server-controlled strings. */
enum { APPLE_PROFILE = 8, APPLE_DECODE = 9, APPLE_GEOMETRY = 10, APPLE_CLIPBOARD = 17 };
/* Archives above the local limit are drained, not inflated. Apple's server caps both sizes at the wire limit. */
enum { CLIPBOARD_TEXT_LIMIT = 1024*1024, CLIPBOARD_ARCHIVE_LIMIT = 8*1024*1024, CLIPBOARD_WIRE_LIMIT = 100*1024*1024 };
static const char clipboardTextType[]="public.utf8-plain-text";

typedef struct {
    uint8_t key[16];
    rfbBool keyValid, baseline, dirty, demand, subscribed;
    double baselineRequestAt;
    uint32_t left, top, right, bottom;
    mvs_decoder *decoder;
    uint32_t clipboardRequestID;
    rfbBool clipboardPending;
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
    rfbRemoraFreeRecords(c);
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
    /* The measured numeric ViewerInfo precedes control mode and pasteboard monitoring.
     * Monitor during the clear prelude, before requesting pixels. */
    uint8_t viewer[66]={0x21,0,0,62,0,1};
    put32(viewer+6,2); put32(viewer+10,6); put32(viewer+14,1);
    put32(viewer+22,26); put32(viewer+26,6); put32(viewer+30,2);
    const uint8_t commands[]={0xb0,0,0x0c,0x03,0x90,0,0,0,0,0,0x40};
    memcpy(viewer+34,commands,sizeof(commands));
    const char mode[4]={0x0a,0,0,1};
    const char monitor[8]={0x15,0,0,1};
    a->baselineRequestAt=monotonic()+1;
    return WriteToRFBServer(c,(char *)viewer,sizeof(viewer)) &&
        WriteToRFBServer(c,mode,sizeof(mode)) &&
        WriteToRFBServer(c,monitor,sizeof(monitor));
}
static rfbBool requestClipboard(rfbClient *c);
rfbBool rfbRemoraAppleEncrypt(rfbClient *c) {
    Apple *a = state(c);
    double deadline = monotonic() + (c->readTimeout ? c->readTimeout : 10);
    rfbBool clipboardChanged = FALSE;
    rfbBool ok = rfbRemoraStartRecords(c, a->key, deadline, &clipboardChanged);
    OPENSSL_cleanse(a->key, sizeof(a->key));
    a->keyValid = FALSE;
    return ok && (!clipboardChanged || requestClipboard(c));
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
    uint8_t message[28]={2,0,0,6};
    put32(message+4,1011); put32(message+8,0); put32(message+12,1105); put32(message+16,(uint32_t)-223); put32(message+20,1101); put32(message+24,1103);
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

static rfbBool requestClipboard(rfbClient *c) {
    Apple *a=state(c);
    uint8_t request[8]={0x0b};
    a->clipboardRequestID=a->clipboardRequestID==UINT32_MAX?1:a->clipboardRequestID+1;
    put32(request+4,a->clipboardRequestID);
    a->clipboardPending=TRUE;
    return WriteToRFBServer(c,(char *)request,sizeof(request));
}

static rfbBool stateChange(rfbClient *c) {
    uint8_t h[3],body[4];
    if(!ReadFromRFBServer(c,(char *)h,sizeof(h))) return FALSE;
    uint32_t n=be16(h+1);
    if(n<sizeof(body)) return fail(c,APPLE_PROFILE);
    if(!ReadFromRFBServer(c,(char *)body,sizeof(body)) || !skip(c,n-sizeof(body))) return FALSE;
    return be16(body)!=1 || be16(body+2)!=2 || requestClipboard(c);
}

/* Keep one bounded output allocation so we can validate the entire archive
 * before publishing text. The compressed input is consumed in fixed chunks. */
static rfbBool inflateClipboard(rfbClient *c,uint32_t compressed,uint8_t *archive,uint32_t length) {
    z_stream z={0};
    if(inflateInit(&z)!=Z_OK) return fail(c,APPLE_CLIPBOARD);
    z.next_out=archive;
    z.avail_out=length+1; /* A sentinel byte detects output beyond the declared size. */
    uint8_t buffer[4096];
    int result=Z_OK;
    while(compressed && result==Z_OK) {
        unsigned chunk=compressed<sizeof(buffer)?compressed:sizeof(buffer);
        if(!ReadFromRFBServer(c,(char *)buffer,chunk)) {
            inflateEnd(&z);
            return FALSE;
        }
        compressed-=chunk;
        z.next_in=buffer; z.avail_in=chunk;
        result=inflate(&z,Z_NO_FLUSH);
        if(z.avail_in || z.total_out>length) break;
    }
    /* A sync flush ends on a byte-aligned nonfinal block boundary (data_type
     * 128). The zlib header alone can have the same flag, so require a block. */
    rfbBool complete=!compressed && !z.avail_in && z.total_out==length &&
        (result==Z_STREAM_END || (result==Z_OK && z.data_type==128 && z.total_in>2));
    inflateEnd(&z);
    return complete || fail(c,APPLE_CLIPBOARD);
}

static const uint8_t *take(const uint8_t **cursor,const uint8_t *end,uint32_t n) {
    if(n>(size_t)(end-*cursor)) return NULL;
    const uint8_t *field=*cursor;
    *cursor+=n;
    return field;
}

static const uint8_t *counted(const uint8_t **cursor,const uint8_t *end,uint32_t *n) {
    const uint8_t *length=take(cursor,end,4);
    if(!length) return NULL;
    *n=be32(length);
    return take(cursor,end,*n);
}

static rfbBool clipboardText(const uint8_t *cursor,uint32_t length,const char **text,int *textLength) {
    const uint8_t *end=cursor+length;
    while(cursor<end) {
        const uint8_t *item=take(&cursor,end,4);
        if(!item) return FALSE;
        uint32_t flavors=be32(item);
        if(flavors>(size_t)(end-cursor)/16) return FALSE;
        for(uint32_t f=0;f<flavors;f++) {
            uint32_t typeLength;
            const uint8_t *type=counted(&cursor,end,&typeLength);
            const uint8_t *flavor=take(&cursor,end,8); /* Flags and tag count. */
            if(!type || !flavor) return FALSE;
            uint32_t tags=be32(flavor+4), size;
            if(tags>(size_t)(end-cursor)/8) return FALSE;
            for(uint32_t t=0;t<tags;t++) {
                if(!counted(&cursor,end,&size) || !counted(&cursor,end,&size)) return FALSE;
            }
            const uint8_t *data=counted(&cursor,end,&size);
            if(!data) return FALSE;
            if(!*text && size<=CLIPBOARD_TEXT_LIMIT && typeLength==sizeof(clipboardTextType)-1 &&
               !memcmp(type,clipboardTextType,typeLength)) {
                *text=(const char *)data; *textLength=(int)size;
            }
        }
    }
    return TRUE;
}

static rfbBool receiveClipboard(rfbClient *c) {
    uint8_t h[15];
    if(!ReadFromRFBServer(c,(char *)h,sizeof(h))) return FALSE;
    uint32_t length=be32(h+7), compressed=be32(h+11);
    if(length>CLIPBOARD_WIRE_LIMIT || !compressed || compressed>CLIPBOARD_WIRE_LIMIT)
        return fail(c,APPLE_CLIPBOARD);
    Apple *a=state(c);
    rfbBool answer=a->clipboardPending && be32(h+3)==a->clipboardRequestID && !(h[1]&1);
    if(length>CLIPBOARD_ARCHIVE_LIMIT || compressed>CLIPBOARD_ARCHIVE_LIMIT) {
        /* A large image can exceed the local limit. Drain it and report the transfer as failed. */
        char buffer[4096];
        while(compressed) {
            unsigned chunk=compressed<sizeof(buffer)?compressed:sizeof(buffer);
            if(!ReadFromRFBServer(c,buffer,chunk)) return FALSE;
            compressed-=chunk;
        }
        if(answer) {
            a->clipboardPending=FALSE;
            if(c->GotXCutTextUTF8) c->GotXCutTextUTF8(c,NULL,0);
        }
        return TRUE;
    }
    uint8_t *archive=malloc(length+1);
    if(!archive) return fail(c,APPLE_CLIPBOARD);
    const char *text=length?NULL:"";
    int textLength=0;
    rfbBool ok=inflateClipboard(c,compressed,archive,length);
    if(ok && !clipboardText(archive,length,&text,&textLength)) ok=fail(c,APPLE_CLIPBOARD);
    if(ok && answer) {
        a->clipboardPending=FALSE;
        if(c->GotXCutTextUTF8) c->GotXCutTextUTF8(c,text,textLength);
    }
    free(archive);
    return ok;
}

rfbBool rfbRemoraAppleClipboard(rfbClient *c,const char *text,int length) {
    if(!state(c) || c->remoraDiagnostic.phase!=RFB_REMORA_READY || length<0 ||
       length>CLIPBOARD_TEXT_LIMIT || (length && !text)) return FALSE;
    enum { TYPE_LENGTH=sizeof(clipboardTextType)-1 };
    uint8_t prefix[20+TYPE_LENGTH]={0};
    unsigned prefixLength=4;
    if(length) {
        put32(prefix,1);
        put32(prefix+4,TYPE_LENGTH);
        memcpy(prefix+8,clipboardTextType,TYPE_LENGTH);
        put32(prefix+16+TYPE_LENGTH,(uint32_t)length);
        prefixLength=sizeof(prefix);
    }
    /* A zero-flavor item clears the pasteboard. An empty flavor is a promise. */
    z_stream z={0};
    if(deflateInit(&z,Z_DEFAULT_COMPRESSION)!=Z_OK) return FALSE;
    uint32_t archiveLength=prefixLength+(uint32_t)length;
    unsigned capacity=(unsigned)deflateBound(&z,archiveLength)+6;
    uint8_t *message=malloc(16+capacity);
    rfbBool ok=FALSE;
    if(message) {
        z.next_out=message+16; z.avail_out=capacity;
        z.next_in=prefix; z.avail_in=prefixLength;
        if(deflate(&z,Z_NO_FLUSH)==Z_OK && !z.avail_in) {
            z.next_in=(Bytef *)text; z.avail_in=(unsigned)length;
            if(deflate(&z,Z_SYNC_FLUSH)==Z_OK && !z.avail_in && z.avail_out) {
                memset(message,0,16); message[0]=0x1f;
                put32(message+8,archiveLength); put32(message+12,(uint32_t)z.total_out);
                ok=WriteToRFBServer(c,(char *)message,16+(unsigned)z.total_out);
            }
        }
    }
    deflateEnd(&z);
    free(message);
    return ok;
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
    uint8_t h[7]; uint32_t n;
    switch(type) {
    case 0: case 2: return 0;
    case 4: case 7: return 1; /* ARDAck and NOP are one-byte messages. */
    case 3:
        if(!ReadFromRFBServer(c,(char *)h,7)) return -1;
        n=be32(h+3); if(n&0x80000000u) n=0u-n;
        return skip(c,n)?1:-1;
    case 0x1f: return receiveClipboard(c)?1:-1;
    case 0x14: return stateChange(c)?1:-1;
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
    if(r->encoding==1103) {
        rfbRemoraFreeRecords(c);
        return fail(c,APPLE_REKEY),-1;
    }
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
rfbBool rfbRemoraApplePointer(rfbClient *c,int x,int y,int mask) {
    /* The common source-button state stays in Remora. Only the wire mask changes. */
    if(!c->remoraRecords || c->remoraDiagnostic.phase!=RFB_REMORA_READY) return FALSE;
    uint8_t pointer[6]={5,(uint8_t)((mask&1)|((mask&4)>>1)|((mask&2)<<1))};
    put16(pointer+2,x); put16(pointer+4,y);
    if(!WriteToRFBServer(c,(char *)pointer,sizeof(pointer))) return FALSE;
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
