/* Loaded only in the resolver regression test's child process. No system
 * permission changes or production resolver injection points are needed. */
#include <dns_sd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct {
    int wake[2];
    DNSServiceGetAddrInfoReply reply;
    void *context;
    const char *host;
    int processFailure;
} fixture;

static DNSServiceRef fixture_ref(void) { return (DNSServiceRef)&fixture; }

static DNSServiceErrorType fixture_get_address(DNSServiceRef *ref, DNSServiceFlags flags,
        uint32_t interface, DNSServiceProtocol protocol, const char *host,
        DNSServiceGetAddrInfoReply reply, void *context) {
    if (strcmp(host, "immediate-policy.remora-test.local") == 0)
        return kDNSServiceErr_PolicyDenied;
    if (strcmp(host, "missing.remora-test.local") == 0)
        return kDNSServiceErr_NoSuchName;
    if (strcmp(host, "callback-policy.remora-test.local") != 0 &&
        strcmp(host, "mixed-policy.remora-test.local") != 0 &&
        strcmp(host, "process-policy.remora-test.local") != 0)
        return DNSServiceGetAddrInfo(ref, flags, interface, protocol, host, reply, context);
    if (pipe(fixture.wake) != 0) return kDNSServiceErr_NoMemory;
    fixture.reply = reply;
    fixture.context = context;
    fixture.host = host;
    fixture.processFailure = strcmp(host, "process-policy.remora-test.local") == 0;
    *ref = fixture_ref();
    char byte = 1;
    if (write(fixture.wake[1], &byte, 1) != 1) abort();
    return kDNSServiceErr_NoError;
}

static int fixture_socket(DNSServiceRef ref) {
    return ref == fixture_ref() ? fixture.wake[0] : DNSServiceRefSockFD(ref);
}

static DNSServiceErrorType fixture_process(DNSServiceRef ref) {
    if (ref != fixture_ref()) return DNSServiceProcessResult(ref);
    char byte;
    if (read(fixture.wake[0], &byte, 1) != 1) abort();
    if (fixture.processFailure) return kDNSServiceErr_PolicyDenied;
    fixture.reply(ref, 0, 0, kDNSServiceErr_PolicyDenied, fixture.host, NULL, 0, fixture.context);
    if (strcmp(fixture.host, "mixed-policy.remora-test.local") == 0)
        fixture.reply(ref, 0, 0, kDNSServiceErr_NoSuchName, fixture.host, NULL, 0, fixture.context);
    return kDNSServiceErr_NoError;
}

static void fixture_deallocate(DNSServiceRef ref) {
    if (ref != fixture_ref()) { DNSServiceRefDeallocate(ref); return; }
    close(fixture.wake[0]);
    close(fixture.wake[1]);
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replace; const void *with; } interpose_##original = \
        { (const void *)&replacement, (const void *)&original }
INTERPOSE(fixture_get_address, DNSServiceGetAddrInfo);
INTERPOSE(fixture_socket, DNSServiceRefSockFD);
INTERPOSE(fixture_process, DNSServiceProcessResult);
INTERPOSE(fixture_deallocate, DNSServiceRefDeallocate);
