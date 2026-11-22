/* Public LibVNCClient loopback lifecycle under ASan/UBSan. No secret inspection seam. */
#include <rfb/rfbclient.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static unsigned frames, failures, expected;
static unsigned clipboardMessages, clipboardChanges;
static int largeClipboard, earlyClipboard;
static int regional;
static rfbCredential *credential(rfbClient *c,int type) {
    (void)c;
    if(type!=rfbCredentialTypeUser) return NULL;
    rfbCredential *v=calloc(1,sizeof(*v));
    v->userCredential.username=strdup("fixture-user");
    v->userCredential.password=strdup("fixture-password");
    return v;
}
static rfbBool allocate(rfbClient *c) {
    if(c->width!=16 || (c->height!=8 && c->height!=16)) return FALSE;
    c->frameBuffer=calloc((size_t)c->width*c->height,4); return c->frameBuffer!=NULL;
}
static void clipboard(rfbClient *c,const char *text,int length) {
    (void)c;
    if(length==-1) {
        if(text) failures++;
        clipboardChanges++;
        return;
    }
    if(earlyClipboard) {
        const char early[]="changed during setup";
        if(clipboardMessages++ || !text || length!=sizeof(early)-1 || memcmp(text,early,length)) failures++;
        return;
    }
    if(largeClipboard) {
        const char after[]="after a large image";
        if(clipboardMessages++<2 ? text || length : !text || length!=sizeof(after)-1 || memcmp(text,after,length)) failures++;
        return;
    }
    const char expectedText[]="from Mac ✓\0";
    switch(clipboardMessages++) {
    case 0:
        if(!text || length!=sizeof(expectedText)-1 || memcmp(text,expectedText,length)) failures++;
        break;
    case 1:
        if(!text || length!=1 || (unsigned char)text[0]!=0xff) failures++;
        break;
    case 2: case 3:
        if(text || length) failures++;
        break;
    default: failures++; break;
    }
}
static void frame(rfbClient *c,int x,int y,int w,int h) {
    if(expected==3 && frames<3) {
        int left=frames==2?8:0, width=frames==0?16:8;
        if(x!=left || y!=0 || w!=width || h!=8) {
            fprintf(stderr,"frame %u damage=(%d,%d,%d,%d) expected=(%d,0,%d,8)\n",frames,x,y,w,h,left,width);
            failures++;
        }
        for(int row=0;row<8;row++) for(int col=0;col<16;col++) {
            uint32_t pixel;
            memcpy(&pixel,c->frameBuffer+((size_t)row*16+col)*4,4);
            uint32_t wanted=frames==0 || (frames==1 && col>=8)?0xff949494u:0xff979394u;
            if(pixel!=wanted) { fprintf(stderr,"frame %u pixel (%d,%d) differs\n",frames,col,row); failures++; }
        }
    }
    if(expected==6 && frames<6) {
        const int damage[][4]={{0,0,16,8},{0,0,16,8},{0,0,8,8},{8,0,8,8},{1,1,12,5},{1,0,15,8}};
        const int *r=damage[frames];
        if(x!=r[0] || y!=r[1] || w!=r[2] || h!=r[3]) {
            fprintf(stderr,"frame %u damage=(%d,%d,%d,%d) expected=(%d,%d,%d,%d)\n",frames,x,y,w,h,r[0],r[1],r[2],r[3]);
            failures++;
        }
    }
    if(regional) {
        int left=frames<2?8:0;
        if(x!=left || y || w!=8 || h!=8) failures++;
        uint32_t pixel;
        memcpy(&pixel,c->frameBuffer+(size_t)left*4,4);
        uint32_t wanted=frames%2?0xff979394u:0xff949494u;
        if(pixel!=wanted) failures++;
    }
    frames++;
}
int main(int argc,char **argv) {
    if(argc!=3 && argc!=4) return 2;
    int demand=argc==4 && !strcmp(argv[3],"demand"), demandTested=0;
    int clipboardExchange=argc==4 && !strcmp(argv[3],"clipboard");
    int invalidClipboard=argc==4 && !strcmp(argv[3],"invalid-clipboard");
    largeClipboard=argc==4 && !strcmp(argv[3],"large-clipboard");
    earlyClipboard=argc==4 && !strcmp(argv[3],"early-clipboard");
    int uploaded=0;
    expected=(unsigned)atoi(argv[2]);
    regional=argc==4 && !strcmp(argv[3],"regions");
    rfbClient *c=rfbGetClient(8,3,4);
    c->remoraApple889=TRUE; c->GetCredential=credential;
    c->format.bigEndian=FALSE; c->format.redShift=16; c->format.greenShift=8; c->format.blueShift=0;
    c->MallocFrameBuffer=allocate; c->GotFrameBufferUpdate=frame;
    if(clipboardExchange || invalidClipboard || largeClipboard || earlyClipboard) c->GotXCutTextUTF8=clipboard;
    c->readTimeout=2; c->connectTimeout=2;
    const uint32_t schemes[]={19,30,2,1}; SetClientAuthSchemes(c,schemes,4);
    int ready=ConnectToRFBServer(c,"127.0.0.1",atoi(argv[1])) && rfbClientInitialise(c);
    if(ready) {
        if(!SendKeyEvent(c,0xffe9,TRUE) || !SendKeyEvent(c,0xffe9,FALSE)) return 3;
        if(argc==4 && !strcmp(argv[3],"large")) {
            char text[70000];
            memset(text,'x',sizeof(text));
            if(!SendClientCutText(c,text,sizeof(text))) return 3;
        }
        for(unsigned i=0;i<64;i++) {
            int n=WaitForMessage(c,100000);
            if(n<0 || (n>0 && !HandleRFBServerMessage(c))) break;
            if(clipboardExchange && !uploaded && clipboardMessages==1) {
                char text[]="from viewer 🦀";
                if(!SendClientCutTextUTF8(c,text,sizeof(text)-1) || !SendClientCutTextUTF8(c,NULL,0)) return 3;
                uploaded=1;
            }
            if(demand && !demandTested && frames==3) {
                if(!rfbRemoraAppleSetDemand(c,FALSE) || !rfbRemoraAppleSetDemand(c,FALSE) ||
                   !rfbRemoraAppleSetDemand(c,TRUE) || !rfbRemoraAppleSetDemand(c,TRUE) ||
                   !SendFramebufferUpdateRequest(c,0,0,c->width,c->height,FALSE)) return 3;
                demandTested=1;
            }
            if(!rfbRemoraAppleRetryBaseline(c)) return 3;
        }
    }
    if(clipboardExchange && (clipboardMessages!=4 || clipboardChanges!=4 || !uploaded || c->remoraAppleError)) failures++;
    if(invalidClipboard && (clipboardMessages || c->remoraAppleError!=17)) failures++;
    if(largeClipboard && (clipboardMessages!=3 || clipboardChanges!=3 || c->remoraAppleError)) failures++;
    if(earlyClipboard && (clipboardMessages!=1 || c->remoraAppleError)) failures++;
    if(argc==4 && (atoi(argv[3]) || !strcmp(argv[3],"0")) && c->remoraAppleError!=atoi(argv[3])) {
        fprintf(stderr,"native error=%d expected=%s\n",c->remoraAppleError,argv[3]); failures++;
    }
    free(c->frameBuffer); c->frameBuffer=NULL; rfbClientCleanup(c);
    if(frames!=expected) { fprintf(stderr,"frames=%u expected=%u\n",frames,expected); return 1; }
    return failures?1:0;
}
