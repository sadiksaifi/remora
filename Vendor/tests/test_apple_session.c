/* Public LibVNCClient loopback lifecycle under ASan/UBSan. No secret inspection seam. */
#include <rfb/rfbclient.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static unsigned frames;
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
static void frame(rfbClient *c,int x,int y,int w,int h) { (void)c;(void)x;(void)y;(void)w;(void)h; frames++; }
int main(int argc,char **argv) {
    if(argc!=3) return 2;
    rfbClient *c=rfbGetClient(8,3,4);
    c->remoraApple889=TRUE; c->GetCredential=credential;
    c->format.bigEndian=FALSE; c->format.redShift=16; c->format.greenShift=8; c->format.blueShift=0;
    c->MallocFrameBuffer=allocate; c->GotFrameBufferUpdate=frame;
    c->readTimeout=2; c->connectTimeout=2;
    const uint32_t schemes[]={19,30,2,1}; SetClientAuthSchemes(c,schemes,4);
    int ready=ConnectToRFBServer(c,"127.0.0.1",atoi(argv[1])) && rfbClientInitialise(c);
    if(ready) {
        if(!SendKeyEvent(c,0xffe9,TRUE) || !SendKeyEvent(c,0xffe9,FALSE)) return 3;
        for(unsigned i=0;i<32;i++) {
            int n=WaitForMessage(c,100000);
            if(n<0 || (n>0 && !HandleRFBServerMessage(c))) break;
        }
    }
    free(c->frameBuffer); c->frameBuffer=NULL; rfbClientCleanup(c);
    unsigned expected=(unsigned)atoi(argv[2]);
    if(frames!=expected) { fprintf(stderr,"frames=%u expected=%u\n",frames,expected); return 1; }
    return 0;
}
