#include "CVNCBridge.h"
#include <rfb/rfbclient.h>
#include <dns_sd.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>

struct RMVNC {
    rfbClient *client;
    RMVNCCallbacks cb;
    void *user;
    pthread_mutex_t lock;
    atomic_bool cancelled;
    int fd, wake[2], error;
    char *host;
    uint16_t port;
    /* Worker-owned resize intent. Wire replies and actual geometry are distinct:
     * forwarded requests may apply after a newer request already matched. */
    uint16_t resizeWidth, resizeHeight, wireResizeWidth, wireResizeHeight;
    int confirmedWidth, confirmedHeight;
    bool resizeActive, resizeQueued, resizeReplyPending, resizeCorrectionUsed, geometryChanged;
    double resizeDeadline;
};
static char client_tag;
static RMVNC *owner(rfbClient *c) { return rfbClientGetClientData(c, &client_tag); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static bool failed(RMVNC *s, int error) { if (!s->error) s->error = error; return false; }
static rfbBool allocate(rfbClient *c) {
    /* Limit remote-controlled allocations to 256 MiB. */
    if (c->width < 1 || c->height < 1 || (uint64_t)c->width * c->height > 67108864) return false;
    uint8_t *pixels = calloc((size_t)c->width * c->height, 4);
    if (!pixels) return false;
    free(c->frameBuffer);
    c->frameBuffer = pixels;
    return true;
}
static void cancel_resize(RMVNC *s) {
    s->resizeActive = s->resizeQueued = s->geometryChanged = s->resizeReplyPending = false;
}
static void resize_reply(rfbClient *c, unsigned int result, uint16_t width, uint16_t height) {
    RMVNC *s = owner(c);
    if (width == s->wireResizeWidth && height == s->wireResizeHeight) s->resizeReplyPending = false;
    if ((result != 0 && result != 4) || !c->remoraResizeSupported) cancel_resize(s);
}
static void size(rfbClient *c, rfbBool requested) {
    RMVNC *s = owner(c);
    if (s->confirmedWidth != c->width || s->confirmedHeight != c->height) s->geometryChanged = true;
    s->confirmedWidth = c->width; s->confirmedHeight = c->height;
    if (!c->remoraResizeSupported) cancel_resize(s);
    if (s->cb.size) s->cb.size(s->user, c->width, c->height, requested);
}
static void frame(rfbClient *c, int x, int y, int w, int h) {
    RMVNC *s = owner(c);
    if (s->cb.frame && !atomic_load(&s->cancelled)) s->cb.frame(s->user, c->frameBuffer, c->width, c->height, x, y, w, h);
}
static void cursor(rfbClient *c, int x, int y, int w, int h, int bpp) {
    RMVNC *s = owner(c);
    if (!s->cb.cursor || bpp != 4 || w < 0 || h < 0 || (uint64_t)w*h > 1048576) return;
    size_t count = (size_t)w*h;
    uint8_t *pixels = count ? malloc(count*4) : NULL;
    if (count && (!pixels || !c->rcSource || !c->rcMask)) { free(pixels); return; }
    for (size_t i=0; i<count; i++) {
        memcpy(pixels+i*4, c->rcSource+i*4, 3);
        pixels[i*4+3] = c->rcMask[i] ? 255 : 0;
    }
    s->cb.cursor(s->user, pixels, w, h, x, y);
    free(pixels);
}
static void clipboard(rfbClient *c, const char *text, int length) {
    RMVNC *s = owner(c);
    if (length >= 0 && length <= 1048576 && s->cb.clipboard) s->cb.clipboard(s->user, text, length, false);
}
static void clipboard_utf8(rfbClient *c, const char *text, int length) {
    RMVNC *s = owner(c);
    if (length >= 0 && length <= 1048576 && s->cb.clipboard) s->cb.clipboard(s->user, text, length, true);
}
static char *password(rfbClient *c) {
    RMVNC *s = owner(c);
    char *username = NULL, *pass = NULL;
    if (!s->cb.credentials || !s->cb.credentials(s->user, false, &username, &pass)) { s->error = 4; free(username); free(pass); return NULL; }
    free(username);
    return pass;
}
static rfbCredential *credential(rfbClient *c, int type) {
    RMVNC *s = owner(c);
    rfbCredential *cred = calloc(1, sizeof(*cred));
    if (!cred) return NULL;
    if (type == rfbCredentialTypeX509) {
        uint8_t pin[32];
        if (s->cb.pin && s->cb.pin(s->user, pin)) {
            cred->x509Credential.x509ExpectedFingerprint = malloc(32);
            if (!cred->x509Credential.x509ExpectedFingerprint) { free(cred); return NULL; }
            memcpy(cred->x509Credential.x509ExpectedFingerprint, pin, 32);
        }
        /* Use macOS' exported system trust roots; explicit pins cover self-signed servers. */
        cred->x509Credential.x509CACertFile = strdup("/etc/ssl/cert.pem");
        return cred;
    }
    if (type != rfbCredentialTypeUser || !s->cb.credentials ||
        !s->cb.credentials(s->user, true, &cred->userCredential.username, &cred->userCredential.password)) {
        s->error = 4; free(cred->userCredential.username); free(cred->userCredential.password); free(cred); return NULL;
    }
    return cred;
}
static rfbBool trust(rfbClient *c, const char *subject, time_t before, time_t after, const uint8_t *pin, size_t length) {
    RMVNC *s = owner(c);
    bool decision = s->cb.trust && s->cb.trust(s->user, subject, pin, length);
    if (!decision) s->error = 5;
    return decision;
}
RMVNC *rm_vnc_create(const char *host, uint16_t port, RMVNCCallbacks cb, void *user) {
    RMVNC *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->fd = -1; s->wake[0] = s->wake[1] = -1;
    pthread_mutex_init(&s->lock, NULL);
    atomic_init(&s->cancelled, false);
    s->host = strdup(host); s->port = port; s->cb = cb; s->user = user;
    if (!s->host || socketpair(AF_UNIX, SOCK_STREAM, 0, s->wake)) { rm_vnc_free(s); return NULL; }
    for (int i=0; i<2; i++) { fcntl(s->wake[i], F_SETFL, O_NONBLOCK); fcntl(s->wake[i], F_SETFD, FD_CLOEXEC); }
    return s;
}
void rm_vnc_abort(RMVNC *s) {
    atomic_store(&s->cancelled, true);
    pthread_mutex_lock(&s->lock);
    if (s->fd >= 0) shutdown(s->fd, SHUT_RDWR);
    if (s->wake[1] >= 0) { char byte=1; (void)write(s->wake[1], &byte, 1); }
    pthread_mutex_unlock(&s->lock);
}
/* DNSServiceGetAddrInfo supplies a cancellable descriptor; no unbounded
 * getaddrinfo worker survives cancellation. Literal endpoints bypass DNS. */
typedef struct { struct sockaddr_storage address[16]; int count; bool done; DNSServiceErrorType error; } Resolution;
static void resolved(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error,
                     const char *host, const struct sockaddr *address, uint32_t ttl, void *context) {
    Resolution *r = context;
    if (error) r->error = error;
    else if ((flags & kDNSServiceFlagsAdd) && address && r->count < 16) {
        size_t len = address->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
        memcpy(&r->address[r->count++], address, len);
    }
    if (r->count && !(flags & kDNSServiceFlagsMoreComing)) r->done = true;
}
static bool resolve(RMVNC *s, Resolution *r) {
    struct sockaddr_in *v4 = (void*)&r->address[0];
    struct sockaddr_in6 *v6 = (void*)&r->address[0];
    if (inet_pton(AF_INET, s->host, &v4->sin_addr) == 1) { v4->sin_family=AF_INET; r->count=1; return true; }
    if (inet_pton(AF_INET6, s->host, &v6->sin6_addr) == 1) { v6->sin6_family=AF_INET6; r->count=1; return true; }
    DNSServiceRef ref = NULL;
    DNSServiceErrorType error = DNSServiceGetAddrInfo(&ref, 0, 0, kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6, s->host, resolved, r);
    if (error) return failed(s, 1);
    double deadline=now()+5;
    while (!r->done && !atomic_load(&s->cancelled) && now()<deadline) {
        struct pollfd fds[2]={{DNSServiceRefSockFD(ref),POLLIN,0},{s->wake[0],POLLIN,0}};
        int ready=poll(fds,2,100);
        if (ready<0 && errno!=EINTR) break;
        if (fds[1].revents) break;
        if (fds[0].revents && DNSServiceProcessResult(ref)) break;
    }
    DNSServiceRefDeallocate(ref);
    return r->count && !atomic_load(&s->cancelled) ? true : failed(s, 1);
}
static bool connect_socket(RMVNC *s) {
    Resolution r={0};
    if (!resolve(s,&r)) return false;
    double deadline=now()+10;
    for (int i=0; i<r.count && !atomic_load(&s->cancelled) && now()<deadline; i++) {
        struct sockaddr *addr=(void*)&r.address[i];
        socklen_t length;
        if (addr->sa_family==AF_INET) { ((struct sockaddr_in*)addr)->sin_port=htons(s->port); length=sizeof(struct sockaddr_in); }
        else { ((struct sockaddr_in6*)addr)->sin6_port=htons(s->port); length=sizeof(struct sockaddr_in6); }
        int fd=socket(addr->sa_family,SOCK_STREAM,0);
        if (fd<0) continue;
        fcntl(fd,F_SETFL,O_NONBLOCK); fcntl(fd,F_SETFD,FD_CLOEXEC);
        int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one)); setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
        pthread_mutex_lock(&s->lock); s->fd=fd;
        if (atomic_load(&s->cancelled)) shutdown(fd,SHUT_RDWR);
        pthread_mutex_unlock(&s->lock);
        int result=connect(fd,addr,length);
        int error=result==0 ? 0 : errno;
        while (result<0 && error==EINPROGRESS && !atomic_load(&s->cancelled) && now()<deadline) {
            struct pollfd fds[2]={{fd,POLLOUT,0},{s->wake[0],POLLIN,0}};
            if (poll(fds,2,100)>0 && fds[0].revents) { socklen_t n=sizeof(error); getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&n); break; }
        }
        if (!error && !atomic_load(&s->cancelled)) return true;
        pthread_mutex_lock(&s->lock); s->fd=-1; close(fd); pthread_mutex_unlock(&s->lock);
        s->error=error==ECONNREFUSED ? 2 : 3;
    }
    return false;
}
bool rm_vnc_connect(RMVNC *s) {
    if (!connect_socket(s)) return false;
    s->error=0;
    rfbClient *c=s->client=rfbGetClient(8,3,4);
    if (!c) return failed(s,6);
    rfbClientSetClientData(c,&client_tag,s);
    c->sock=s->fd;
    free(c->serverHost); c->serverHost=strdup(s->host); c->serverPort=s->port;
    c->connectTimeout=10; c->readTimeout=10;
    c->format.bigEndian=false; c->format.trueColour=true;
    c->format.redShift=16; c->format.greenShift=8; c->format.blueShift=0;
    c->format.redMax=c->format.greenMax=c->format.blueMax=255;
    c->RemoraDesktopSize=size; c->RemoraResizeReply=resize_reply;
    c->MallocFrameBuffer=allocate; c->GotFrameBufferUpdate=frame; c->GotCursorShape=cursor;
    c->GotXCutText=clipboard; c->GotXCutTextUTF8=clipboard_utf8;
    c->GetPassword=password; c->GetCredential=credential; c->GetX509CertFingerprintMismatchDecision=trust;
    c->appData.encodingsString="tight zrle hextile copyrect raw";
    c->appData.useRemoteCursor=true; c->canHandleNewFBSize=true;
    const uint32_t schemes[]={rfbVeNCrypt,rfbARD,rfbVncAuth,rfbNoAuth};
    SetClientAuthSchemes(c,schemes,4);
    if (!rfbClientInitialise(c)) return failed(s,c->remoraAuthFailed ? 4 : 6);
    size(c, false);
    s->error=0;
    return !atomic_load(&s->cancelled);
}
/* One corrective request per admitted explicit target, within three seconds.
 * Matches and repeated notifications never renew either bound. */
static bool reconcile_resize(RMVNC *s) {
    rfbClient *c = s->client;
    if (!c->remoraResizeSupported || now() >= s->resizeDeadline) cancel_resize(s);
    if (!s->resizeActive || s->resizeReplyPending) return true;
    bool correct = s->geometryChanged && !s->resizeCorrectionUsed &&
        (c->width != s->resizeWidth || c->height != s->resizeHeight);
    if (!s->resizeQueued && !correct) { s->geometryChanged = false; return true; }
    if (!s->resizeQueued) s->resizeCorrectionUsed = true;
    s->resizeQueued = s->geometryChanged = false;
    /* The library suppresses an already-confirmed, already-sent size. That
     * no-op has no wire reply to await. */
    s->resizeReplyPending = c->screen.width != htons(s->resizeWidth) ||
        c->screen.height != htons(s->resizeHeight) ||
        (c->remoraLastResizeWidth && (c->remoraLastResizeWidth != s->resizeWidth || c->remoraLastResizeHeight != s->resizeHeight));
    s->wireResizeWidth = s->resizeWidth; s->wireResizeHeight = s->resizeHeight;
    return SendExtDesktopSize(c, s->resizeWidth, s->resizeHeight);
}
bool rm_vnc_step(RMVNC *s) {
    if (atomic_load(&s->cancelled)) return false;
    int ready=WaitForMessage(s->client,10000);
    if (ready < 0 || (ready && !HandleRFBServerMessage(s->client))) { cancel_resize(s); return false; }
    return !atomic_load(&s->cancelled) && reconcile_resize(s);
}
int rm_vnc_error(RMVNC *s) { return s->error; }
const char *rm_vnc_security(RMVNC *s) {
    if (!s->client) return "unnegotiated";
    switch(s->client->authScheme) {
        case rfbVeNCrypt: switch(s->client->subAuthScheme) {
            case rfbVeNCryptX509Plain: return "VeNCrypt X509Plain";
            case rfbVeNCryptX509VNC: return "VeNCrypt X509VNC";
            case rfbVeNCryptX509None: return "VeNCrypt X509None";
        } return "unsupported VeNCrypt subtype";
        case rfbARD: return "Apple ARD (unencrypted desktop)";
        case rfbVncAuth: return "VNC authentication (unencrypted desktop)";
        case rfbNoAuth: return "None (unencrypted, unauthenticated desktop)";
        default:return "unsupported security type (RSA-AES is not supported)";
    }
}
bool rm_vnc_resize_supported(RMVNC *s) { return s->client->remoraResizeSupported; }
bool rm_vnc_resize(RMVNC *s,uint16_t w,uint16_t h) {
    if (atomic_load(&s->cancelled) || !s->client->remoraResizeSupported) return true;
    if (now() >= s->resizeDeadline) cancel_resize(s);
    if (s->resizeActive && s->resizeWidth == w && s->resizeHeight == h) return true;
    s->resizeWidth = w; s->resizeHeight = h;
    s->resizeActive = s->resizeQueued = true;
    s->resizeCorrectionUsed = s->geometryChanged = false;
    s->resizeDeadline = now() + 3;
    return reconcile_resize(s);
}
bool rm_vnc_refresh(RMVNC *s) { return SendFramebufferUpdateRequest(s->client,0,0,s->client->width,s->client->height,false); }
bool rm_vnc_key(RMVNC *s,uint32_t sym,uint32_t code,bool down) {
    if (code && SupportsClient2Server(s->client,rfbQemuEvent)) return SendExtendedKeyEvent(s->client,sym,code,down);
    return SendKeyEvent(s->client,sym,down);
}
bool rm_vnc_pointer(RMVNC *s,uint16_t x,uint16_t y,uint8_t mask) { return SendPointerEvent(s->client,x,y,mask); }
bool rm_vnc_clipboard_utf8(RMVNC *s) { return s->client->extendedClipboardServerCapabilities != 0; }
bool rm_vnc_clipboard(RMVNC *s,const char *text,int len,bool utf8) {
    return utf8 ? SendClientCutTextUTF8(s->client,(char*)text,len) : SendClientCutText(s->client,(char*)text,len);
}
void rm_vnc_free(RMVNC *s) {
    if (!s) return;
    pthread_mutex_lock(&s->lock);
    if (s->client) {
        free(s->client->frameBuffer); s->client->frameBuffer=NULL;
        rfbClientCleanup(s->client); /* closes socket */
    } else if (s->fd>=0) close(s->fd);
    s->fd=-1;
    if(s->wake[0]>=0) close(s->wake[0]);
    if(s->wake[1]>=0) close(s->wake[1]);
    pthread_mutex_unlock(&s->lock);
    pthread_mutex_destroy(&s->lock);
    free(s->host); free(s);
}
