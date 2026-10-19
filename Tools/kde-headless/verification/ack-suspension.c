#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <time.h>
#include <freerdp/server/rdpgfx.h>

// One isolated test connection. Intercept only the FreeRDP server API boundary.
static psRdpgfxServerOpen original_open;
static psRdpgfxFrameAcknowledge original_ack;
static unsigned count;
static unsigned suppressed;
static double deadline;
static double now_seconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}
static UINT probe_ack(RdpgfxServerContext *context, const RDPGFX_FRAME_ACKNOWLEDGE_PDU *ack)
{
    ++count;
    if (count == 20) {
        RDPGFX_FRAME_ACKNOWLEDGE_PDU suspended = *ack;
        suspended.queueDepth = SUSPEND_FRAME_ACKNOWLEDGEMENT;
        deadline = now_seconds() + 3;
        fprintf(stderr, "ACK_PROBE suspend frame=%u\n", ack->frameId);
        return original_ack(context, &suspended);
    }
    if (deadline && now_seconds() < deadline) {
        ++suppressed;
        return CHANNEL_RC_OK;
    }
    if (deadline) {
        fprintf(stderr, "ACK_PROBE resume frame=%u suppressed=%u\n", ack->frameId, suppressed);
        deadline = 0;
    }
    return original_ack(context, ack);
}
static BOOL probe_open(RdpgfxServerContext *context)
{
    original_ack = context->FrameAcknowledge;
    context->FrameAcknowledge = probe_ack;
    return original_open(context);
}
RdpgfxServerContext *rdpgfx_server_context_new(HANDLE manager)
{
    RdpgfxServerContext *(*create)(HANDLE) = dlsym(RTLD_NEXT, "rdpgfx_server_context_new");
    RdpgfxServerContext *context = create(manager);
    if (context) {
        count = suppressed = 0;
        deadline = 0;
        original_open = context->Open;
        context->Open = probe_open;
    }
    return context;
}
