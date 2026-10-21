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
#include <os/signpost.h>
#include <dispatch/dispatch.h>

struct RMVNC {
    rfbClient *client;
    RMVNCDiagnostic diagnostic;
    double started;
    os_signpost_id_t performanceID;
    RMVNCCallbacks cb;
    void *user;
    pthread_mutex_t lock;
    atomic_bool cancelled, inputPending;
    unsigned inputBusy;
    double inputServiceAt;
    int fd, wake[2], error;
    char *host;
    uint16_t port;
    bool apple;
    /* Worker-owned resize intent. Wire replies and actual geometry are distinct:
     * forwarded requests may apply after a newer request already matched. */
    uint16_t resizeWidth, resizeHeight, wireResizeWidth, wireResizeHeight;
    int confirmedWidth, confirmedHeight;
    bool resizeActive, resizeQueued, resizeReplyPending, resizeCorrectionUsed, geometryChanged;
    double resizeDeadline;
};
uint32_t rm_vnc_apple_keysym(uint32_t);
static char client_tag;
static RMVNC *owner(rfbClient *c) { return rfbClientGetClientData(c, &client_tag); }
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
/* DynamicTracing is recording-only. No per-read clocks or counters run when
 * disabled. This state is independent of remoraRuntime's first-failure context. */
static os_log_t performance_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.sadiksaifi.Remora", OS_LOG_CATEGORY_DYNAMIC_TRACING); });
    return log;
}
/* A DynamicTracing ID generated before attachment is NULL. Generate lazily
 * at enabled event sites; retain each valid ID for this client's lifetime. */
static os_signpost_id_t performance_id(RMVNC *s) {
    if (s->performanceID == OS_SIGNPOST_ID_NULL)
        s->performanceID = os_signpost_id_generate(performance_log());
    return s->performanceID;
}
static uint64_t performance_clock(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t performance_cpu(void) {
    struct timespec t;
    return clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) == 0 ? (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec : 0;
}
static long long performance_us(uint64_t end, uint64_t start) { return end >= start && start ? (long long)((end-start)/1000) : -1; }
static void performance(rfbClient *c, unsigned event) {
    rfbRemoraPerformance *p = &c->remoraPerf;
    bool recording = os_signpost_enabled(performance_log());
    if (!recording) { p->enabled = false; p->lastRequest = p->requestStart = 0; return; }
    if (event == RFB_REMORA_PERF_REQUEST_BEGIN) {
        p->requestStart = performance_clock();
        return;
    }
    if (event == RFB_REMORA_PERF_PARSED) {
        if (!p->enabled) return;
        p->end = performance_clock(); p->cpuEnd = performance_cpu();
        p->bufferedEnd = c->buffered; p->ended = true;
        return;
    }
    bool ok = event == RFB_REMORA_PERF_REQUEST_OK;
    uint64_t end = performance_clock();
    os_signpost_event_emit(performance_log(), performance_id(owner(c)), "VNCRequest",
        "seq=%{public}llu incremental=%{public}u full_area=%{public}u write_us=%{public}lld ok=%{public}d",
        p->sequence, p->requestIncremental, p->requestFull, performance_us(end,p->requestStart), ok);
    if (p->enabled && p->active && !p->ended) p->requestsDuring++;
    p->lastRequest = ok ? end : 0;
}
static void performance_input(RMVNC *s, unsigned kind, bool ok) {
    rfbRemoraPerformance *p = &s->client->remoraPerf;
    if (!os_signpost_enabled(performance_log())) { p->enabled = false; return; }
    if (ok && p->enabled && p->active && !p->ended) p->inputsDuring++;
    os_signpost_event_emit(performance_log(), performance_id(s), "VNCInput",
        "seq=%{public}llu kind=%{public}u ok=%{public}d", p->sequence, kind, ok);
}
static void performance_update(RMVNC *s, bool ok) {
    rfbRemoraPerformance *p = &s->client->remoraPerf;
    if (!p->enabled || !p->active || !os_signpost_enabled(performance_log())) return;
    ok = ok && p->ended;
    os_signpost_event_emit(performance_log(), performance_id(s), "VNCUpdate",
        "seq=%{public}llu ok=%{public}d declared_rects=%{public}u header_known=%{public}d wire_rects=%{public}u callbacks=%{public}u "
        "request_known=%{public}d prefetched_start=%{public}d req_to_ready_us=%{public}lld ready_to_header_us=%{public}lld message_us=%{public}lld "
        "read_wait_us=%{public}lld logical_bytes=%{public}lld buffered_end=%{public}lld cpu_us=%{public}lld callback_us=%{public}lld "
        "area_sum=%{public}llu area_max=%{public}llu enc_mask=%{public}llu requests_during=%{public}u inputs_during=%{public}u",
        p->sequence, ok, p->declaredRects, p->header != 0, p->wireRects, p->callbacks,
        p->requestAtReady != 0 && !p->prefetched, p->prefetched,
        ok && !p->prefetched ? performance_us(p->ready,p->requestAtReady) : -1,
        ok ? performance_us(p->header,p->ready) : -1,
        ok ? performance_us(p->end,p->ready) : -1,
        ok ? (long long)(p->waitNS/1000) : -1, ok ? (long long)p->logicalBytes : -1,
        ok ? (long long)p->bufferedEnd : -1, ok ? performance_us(p->cpuEnd,p->cpuStart) : -1,
        ok ? (long long)(p->callbackNS/1000) : -1,
        p->areaSum, p->areaMax, p->encMask, p->requestsDuring, p->inputsDuring);
}
static bool failed(RMVNC *s, int error) {
    if (!s->error) s->error = error;
    if (s->client) rfbRemoraDiagnosticFail(s->client, RFB_REMORA_PROTOCOL, 0, 0);
    else if (!s->diagnostic.failure) s->diagnostic.failure = error == 6 ? RFB_REMORA_MEMORY : error == 3 ? RFB_REMORA_TIMEOUT : RFB_REMORA_IO;
    return false;
}
void rm_vnc_set_input_pending(RMVNC *s, bool pending) { atomic_store(&s->inputPending, pending); }
static rfbBool service_input(rfbClient *c) {
    RMVNC *s = owner(c);
    if (atomic_load(&s->cancelled)) return false;
    if (c->remoraPerf.enabled && !os_signpost_enabled(performance_log())) c->remoraPerf.enabled = false;
    if (s->inputBusy || !atomic_load(&s->inputPending) || now() < s->inputServiceAt) return true;
    s->inputServiceAt = now() + 0.005;
    rfbRemoraRuntimeDiagnostic context = c->remoraRuntime;
    s->inputBusy++;
    bool accepted = !s->cb.serviceInput || s->cb.serviceInput(s->user);
    s->inputBusy--;
    if (!c->remoraRuntime.failure) c->remoraRuntime = context;
    if (!accepted && !atomic_load(&s->cancelled)) {
        rfbRemoraRuntimeStage(c, RFB_REMORA_WRITE);
        rfbRemoraRuntimeFail(c, RFB_REMORA_CALLBACK, 0, 0);
    }
    return accepted && !atomic_load(&s->cancelled);
}
void rm_vnc_enable_input_service(RMVNC *s) { s->client->RemoraServiceInput = service_input; }
static rfbBool update_allowed(rfbClient *c, rfbBool early) {
    RMVNC *s = owner(c);
    return c->remoraDiagnostic.phase == RFB_REMORA_READY && !atomic_load(&s->cancelled) &&
        (!early || (!s->resizeActive && !s->resizeReplyPending && !c->requestedResize));
}
static rfbBool allocate(rfbClient *c) {
    /* MetalDesktop accepts at most 16384 pixels per axis and 256 MiB total. */
    if (c->width > 16384 || c->height > 16384 ||
        (c->width > 0 && c->height > 0 && (uint64_t)c->width * c->height > 67108864)) {
        owner(c)->error = 7;
        rfbRemoraRuntimeStage(c, RFB_REMORA_RUNTIME_ALLOCATE);
        rfbRemoraDiagnosticFail(c, RFB_REMORA_DESKTOP_SIZE, 0, 0);
        return false;
    }
    if (c->width < 1 || c->height < 1) {
        rfbRemoraRuntimeStage(c, RFB_REMORA_RUNTIME_ALLOCATE);
        rfbRemoraRuntimeFail(c, RFB_REMORA_ALLOCATION, 0, 0);
        return false;
    }
    uint8_t *pixels = calloc((size_t)c->width * c->height, 4);
    if (!pixels) {
        rfbRemoraRuntimeStage(c, RFB_REMORA_RUNTIME_ALLOCATE);
        rfbRemoraRuntimeFail(c, RFB_REMORA_ALLOCATION, 0, 0);
        return false;
    }
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
    if (s->cb.frame && !atomic_load(&s->cancelled)) {
        if (!c->remoraRuntime.failure && c->remoraRuntime.callbacks < UINT32_MAX) c->remoraRuntime.callbacks++;
        rfbRemoraPerformance *p = &c->remoraPerf;
        bool recording = p->enabled && p->active && os_signpost_enabled(performance_log());
        uint64_t began = recording ? performance_clock() : 0;
        if (recording) {
            uint64_t area = (uint64_t)w*h;
            unsigned bit;
            switch ((int32_t)c->remoraRuntime.encoding) {
                case rfbEncodingRaw: bit=0; break; case rfbEncodingCopyRect: bit=1; break;
                case rfbEncodingHextile: bit=2; break; case rfbEncodingZlib: bit=3; break;
                case rfbEncodingZRLE: bit=4; break; case rfbEncodingTight: bit=5; break; default: bit=6;
            }
            p->callbacks++; p->areaSum += area; if (area > p->areaMax) p->areaMax = area;
            p->encMask |= (uint64_t)1 << bit;
            os_signpost_event_emit(performance_log(), performance_id(s), "VNCPixelRect",
                "seq=%{public}llu index=%{public}d x=%{public}d y=%{public}d w=%{public}d h=%{public}d encoding=%{public}lld "
                "rect_bytes=%{public}llu zrle_len=%{public}lld header_to_len_us=%{public}lld len_to_body_us=%{public}lld body_to_callback_us=%{public}lld rect_wait_us=%{public}llu",
                p->sequence, c->remoraRuntime.rectIndex, x,y,w,h,(long long)c->remoraRuntime.encoding,
                p->logicalBytes-p->rectBytesStart, (long long)p->zrleLength,
                performance_us(p->zrleLengthAt,p->rectHeader), performance_us(p->bodyAt,p->zrleLengthAt),
                performance_us(began,p->bodyAt), (p->waitNS-p->rectWaitStart)/1000);
        }
        s->cb.frame(s->user, c->frameBuffer, c->width, c->height, x, y, w, h);
        if (recording) {
            p->lastCallback = performance_clock(); p->callbackNS += p->lastCallback-began;
        }
    }
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
RMVNC *rm_vnc_create(const char *host, uint16_t port, bool apple, RMVNCCallbacks cb, void *user) {
    RMVNC *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->started = now(); s->apple=apple;
    s->fd = -1; s->wake[0] = s->wake[1] = -1;
    pthread_mutex_init(&s->lock, NULL);
    atomic_init(&s->cancelled, false);
    atomic_init(&s->inputPending, false);
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
    s->diagnostic.phase = RFB_REMORA_DNS;
    if (!resolve(s,&r)) return false;
    s->diagnostic.lastSuccess = RFB_REMORA_DNS;
    s->diagnostic.phase = RFB_REMORA_TCP;
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
        if (!error && !atomic_load(&s->cancelled)) { s->diagnostic.lastSuccess = RFB_REMORA_TCP; return true; }
        pthread_mutex_lock(&s->lock); s->fd=-1; close(fd); pthread_mutex_unlock(&s->lock);
        s->diagnostic.systemError = error;
        s->error=error==ECONNREFUSED ? 2 : 3;
    }
    return false;
}
bool rm_vnc_connect(RMVNC *s) {
    if (!connect_socket(s)) {
        if (!s->diagnostic.failure) s->diagnostic.failure = s->error == 3 ? RFB_REMORA_TIMEOUT : RFB_REMORA_IO;
        return false;
    }
    s->error=0;
    rfbClient *c=s->client=rfbGetClient(8,3,4);
    if (!c) return failed(s,6);
    c->RemoraPerformance = performance; c->RemoraPerformanceClock = performance_clock;
    c->remoraDiagnostic.phase = c->remoraDiagnostic.lastSuccess = RFB_REMORA_TCP;
    rfbClientSetClientData(c,&client_tag,s);
    c->sock=s->fd; c->remoraApple889=s->apple;
    free(c->serverHost); c->serverHost=strdup(s->host); c->serverPort=s->port;
    c->connectTimeout=10; c->readTimeout=10;
    c->format.bigEndian=false; c->format.trueColour=true;
    c->format.redShift=16; c->format.greenShift=8; c->format.blueShift=0;
    c->format.redMax=c->format.greenMax=c->format.blueMax=255;
    c->RemoraDesktopSize=size; c->RemoraResizeReply=resize_reply;
    c->RemoraUpdateAllowed=update_allowed;
    c->MallocFrameBuffer=allocate; c->GotFrameBufferUpdate=frame; c->GotCursorShape=cursor;
    c->GotXCutText=clipboard; c->GotXCutTextUTF8=clipboard_utf8;
    c->GetPassword=password; c->GetCredential=credential; c->GetX509CertFingerprintMismatchDecision=trust;
    c->appData.encodingsString="tight zrle hextile copyrect raw";
    c->appData.useRemoteCursor=true; c->canHandleNewFBSize=true;
    const uint32_t schemes[]={rfbVeNCrypt,rfbARD,rfbVncAuth,rfbNoAuth};
    SetClientAuthSchemes(c,schemes,4);
    if (!rfbClientInitialise(c)) return failed(s,c->remoraAuthFailed ? 4 : c->remoraAppleError ? c->remoraAppleError : 6);
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
    rfbRemoraRuntimeMessage(c, RFB_REMORA_WRITE);
    s->inputBusy++;
    bool sent = SendExtDesktopSize(c, s->resizeWidth, s->resizeHeight);
    s->inputBusy--;
    return sent;
}
bool rm_vnc_step(RMVNC *s) {
    if (atomic_load(&s->cancelled)) return false;
    rfbRemoraRuntimeMessage(s->client, RFB_REMORA_WAIT);
    rfbClient *c = s->client;
    rfbRemoraPerformance *p = &c->remoraPerf;
    uint64_t sequence = p->sequence, lastRequest = p->lastRequest;
    memset(p,0,sizeof(*p)); p->sequence = sequence; p->lastRequest = lastRequest;
    p->enabled = os_signpost_enabled(performance_log());
    if (!p->enabled) p->lastRequest = lastRequest = 0;
    p->prefetched = c->buffered > 0;
    int ready=WaitForMessage(c,10000);
    if (ready > 0 && p->enabled) {
        p->ready = performance_clock(); p->cpuStart = performance_cpu(); p->requestAtReady = lastRequest;
    }
    bool handled = ready > 0 ? HandleRFBServerMessage(c) : true;
    performance_update(s,handled);
    p->enabled = false;
    if (ready < 0 || !handled) {
        rfbRemoraRuntimeOperation(s->client, 0);
        if (!atomic_load(&s->cancelled)) rfbRemoraRuntimeFail(s->client, RFB_REMORA_DECODER, 0, 0);
        cancel_resize(s); return false;
    }
    return !atomic_load(&s->cancelled) && reconcile_resize(s);
}
RMVNCDiagnostic rm_vnc_diagnostic(RMVNC *s) {
    RMVNCDiagnostic result = s->diagnostic;
    if (s->client) {
        const rfbRemoraDiagnostic *d = &s->client->remoraDiagnostic;
        result.phase = d->phase; result.lastSuccess = d->lastSuccess; result.failure = d->failure;
        result.systemError = d->systemError; result.opensslError = d->opensslError;
        result.framebufferWidth = s->client->width; result.framebufferHeight = s->client->height;
        result.serverMajor = d->serverMajor; result.serverMinor = d->serverMinor;
        result.negotiatedMajor = d->negotiatedMajor; result.negotiatedMinor = d->negotiatedMinor;
        result.offeredCount = d->offeredCount; result.selected = d->selected;
        result.subofferedCount = d->subofferedCount; result.subtype = d->subtype; result.ardBits = d->ardBits;
        for (unsigned i = 0; i < 32; i++) { result.offered[i] = d->offered[i]; result.suboffered[i] = d->suboffered[i]; }
    }
    result.elapsedMS = (uint64_t)((now() - s->started) * 1000);
    result.cancelled = atomic_load(&s->cancelled);
    return result;
}
RMVNCRuntimeDiagnostic rm_vnc_runtime_diagnostic(RMVNC *s) {
    RMVNCRuntimeDiagnostic result = {0};
    if (s->client) {
        const rfbRemoraRuntimeDiagnostic *d = &s->client->remoraRuntime;
        result.stage = d->stage; result.failure = d->failure; result.operation = d->operation;
        result.systemError = d->systemError; result.sslError = d->sslError; result.opensslError = d->opensslError;
        result.messageType = d->messageType; result.rectIndex = d->rectIndex; result.rectCount = d->rectCount;
        result.encoding = d->encoding; result.x = d->x; result.y = d->y; result.width = d->width; result.height = d->height;
        result.framebufferWidth = d->framebufferWidth; result.framebufferHeight = d->framebufferHeight;
        result.callbacks = d->callbacks;
    }
    result.elapsedMS = (uint64_t)((now() - s->started) * 1000);
    result.cancelled = atomic_load(&s->cancelled);
    return result;
}
int rm_vnc_error(RMVNC *s) {
    if (s->error && s->error!=6) return s->error;
    return s->client && s->client->remoraAppleError ? s->client->remoraAppleError : s->error;
}
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
bool rm_vnc_resize_supported(RMVNC *s) { return !s->apple && s->client->remoraResizeSupported; }
bool rm_vnc_resize(RMVNC *s,uint16_t w,uint16_t h) {
    if (atomic_load(&s->cancelled) || s->apple || !s->client->remoraResizeSupported) return true;
    if (now() >= s->resizeDeadline) cancel_resize(s);
    if (s->resizeActive && s->resizeWidth == w && s->resizeHeight == h) return true;
    s->resizeWidth = w; s->resizeHeight = h;
    s->resizeActive = s->resizeQueued = true;
    s->resizeCorrectionUsed = s->geometryChanged = false;
    s->resizeDeadline = now() + 3;
    return reconcile_resize(s);
}
bool rm_vnc_set_display_demand(RMVNC *s, bool enabled) {
    if (!s->apple) return true;
    if (atomic_load(&s->cancelled)) return false;
    s->inputBusy++;
    bool sent=rfbRemoraAppleSetDemand(s->client,enabled);
    s->inputBusy--; return sent;
}
bool rm_vnc_refresh(RMVNC *s) {
    rfbRemoraRuntimeMessage(s->client, RFB_REMORA_WRITE);
    s->inputBusy++;
    bool sent = SendFramebufferUpdateRequest(s->client,0,0,s->client->width,s->client->height,false);
    s->inputBusy--; return sent;
}
bool rm_vnc_key(RMVNC *s,uint32_t sym,uint32_t code,bool down) {
    rfbRemoraRuntimeMessage(s->client, RFB_REMORA_WRITE);
    s->inputBusy++;
    if (s->apple) sym=rm_vnc_apple_keysym(sym);
    bool sent = code && SupportsClient2Server(s->client,rfbQemuEvent)
        ? SendExtendedKeyEvent(s->client,sym,code,down) : SendKeyEvent(s->client,sym,down);
    s->inputBusy--; performance_input(s,1,sent); return sent;
}
bool rm_vnc_pointer(RMVNC *s,uint16_t x,uint16_t y,uint8_t mask) {
    rfbRemoraRuntimeMessage(s->client, RFB_REMORA_WRITE);
    s->inputBusy++;
    bool sent = SendPointerEvent(s->client,x,y,mask);
    s->inputBusy--; performance_input(s,2,sent); return sent;
}
bool rm_vnc_clipboard_utf8(RMVNC *s) { return s->client->extendedClipboardServerCapabilities != 0; }
bool rm_vnc_clipboard(RMVNC *s,const char *text,int len,bool utf8) {
    rfbRemoraRuntimeMessage(s->client, RFB_REMORA_WRITE);
    s->inputBusy++;
    if (s->apple) { s->inputBusy--; return false; }
    bool sent = utf8 ? SendClientCutTextUTF8(s->client,(char*)text,len) : SendClientCutText(s->client,(char*)text,len);
    s->inputBusy--; return sent;
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
