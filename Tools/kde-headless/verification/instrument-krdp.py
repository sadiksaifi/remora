#!/usr/bin/env python3
"""Add temporary per-frame diagnostics to a private KRdp 6.3.5 source tree."""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('Usage: instrument-krdp.py SOURCE_DIRECTORY')
src = Path(sys.argv[1])
p = src / 'src/VideoStream.cpp'
s = p.read_text()
if 'PERF_SEND' in s:
    raise SystemExit('This source tree already contains performance instrumentation')
# Both revisions: stamp accepted encoder packets, then measure their wait before send.
s=s.replace('d->frameQueue.append(frame);','''auto stamped = frame;
        stamped.presentationTimeStamp = clk::system_clock::now();
        d->frameQueue.append(stamped);
        qInfo() << "PERF_QUEUE" << clk::duration_cast<clk::microseconds>(clk::steady_clock::now().time_since_epoch()).count() << d->frameQueue.size();''')
anchor='    auto frameId = d->frameId++;'
s=s.replace(anchor,anchor+'''
    qInfo() << "PERF_SEND" << clk::duration_cast<clk::microseconds>(clk::steady_clock::now().time_since_epoch()).count()
            << frameId << frame.data.size() << d->requestedFrameRate
            << "wait_us" << clk::duration_cast<clk::microseconds>(clk::system_clock::now() - frame.presentationTimeStamp).count();''')
anchor='    auto id = frameAcknowledge->frameId;'
ack='''    qInfo() << "PERF_ACK" << clk::duration_cast<clk::microseconds>(clk::steady_clock::now().time_since_epoch()).count()
            << frameAcknowledge->frameId << frameAcknowledge->queueDepth << d->requestedFrameRate;
'''
if anchor in s:
    s = s.replace(anchor, ack + anchor)
else:
    signature = 'uint32_t VideoStream::onFrameAcknowledge(const RDPGFX_FRAME_ACKNOWLEDGE_PDU *frameAcknowledge)\n{'
    s = s.replace(signature, signature + '\n' + ack)
s=s.replace('    d->maxInFlight.store(window);','    d->maxInFlight.store(window);\n    qInfo() << "PERF_WINDOW" << window << "rtt_ms" << rttMs;')
s=s.replace('        d->encoderPaused = true;','        d->encoderPaused = true;\n        qInfo() << "PERF_PAUSE" << queued;').replace('        d->encoderPaused = false;','        d->encoderPaused = false;\n        qInfo() << "PERF_RESUME" << queued;')
p.write_text(s)
