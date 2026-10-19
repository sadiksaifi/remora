# KDE motion and flow control

The private KRdp/KPipeWire backport approximately doubled delivered desktop
motion in this test. It removes KRdp's unnecessary capture-rate reduction and
replaces it with ACK and encoder backpressure. It does not establish parity
with GNOME or Windows.

## Cause and scope

KRdp 6.3.5 estimates source FPS from RTT multiplied by an outstanding-frame
estimate, averages that estimate, then halves it. Old estimates also fail to
expire because the timestamp subtraction is reversed. On the tested connection,
the source cap fell below the virtual output's 60 Hz even when the send queue
was empty. The sender then polled an empty queue once per requested frame period.

The adaptation follows these upstream changes:

- [Remove the RTT source-rate heuristic, 978f1cb7](https://github.com/KDE/krdp/commit/978f1cb7e020d96a274947b08caae2b14f7533f3).
- [Size the in-flight window from RTT, 909f866e](https://github.com/KDE/krdp/commit/909f866e375234601870b5d1ac899566fa89085c).
- [Pause before encoding, KPipeWire 326e8ec3](https://github.com/KDE/kpipewire/commit/326e8ec349288e6b377168f90c6499dd97f0dccf).
- [Apply encoder backpressure, KRdp d3b06515](https://github.com/KDE/krdp/commit/d3b06515f0ae797733c0175a4775eaa73e7af02f).
- [Handle suspended acknowledgements, fe003738](https://github.com/KDE/krdp/commit/fe0037384404b74895bff5a5f4cf411a62f1c712).

These are adaptations to Debian's older APIs, not cherry-picks. KRdp 6.3 keeps
its encoder in `AbstractSession`, so `SessionController` forwards the pause
signal there. Its existing default capture rate remains 60 FPS. The patch also
replaces sender polling with a stop-aware condition variable. Queue, ACK,
capability, and RTT state shared by threads receive synchronization.

The in-flight limit is `ceil(60 * RTT_seconds)`, clamped to 2 through 60 frames.
The encoded send queue pauses the producer above three queued packets and
resumes it when empty. The encoder's combined filter/encode pending budget is
three frames, KPipeWire 6.3's minimum. Source frames are coalesced before encoding; encoded H.264 packets
remain in order. The repeat timer respects pause and capacity. The latest
paused frame is submitted after resume, including when the desktop becomes
stationary. Pause state survives producer recreation, and cached frames are
cleared on format setup.

A suspended-ACK PDU clears pending IDs and disables ACK tracking until a normal
ACK returns. Exact ID matching avoids ordered arithmetic across uint32 wrap.
Normal ACKs, reconnect, suspension, and blocked shutdown were exercised. A full
frame-ID wrap was reviewed in code rather than exercised over billions of frames.

## Applying and building

Use Debian source packages `krdp=6.3.5-1` and `kpipewire=6.3.6-1`, including their
Debian patches. KPipeWire's internal CMake/library version is `6.3.90` in this
package. Keep the system packages installed.

1. Apply the existing KWin patches in the order in [verification.md](verification.md).
2. Apply `patches/krdp-6.3.5-input.patch` to KRdp.
3. Apply `patches/kpipewire-6.3.6-encoder-backpressure.patch` to KPipeWire and build/install it into a private prefix.
4. Apply `patches/krdp-6.3.5-bounded-flow.patch` to KRdp. Configure against the private KPipeWire CMake package, then rebuild/install both the KRdp library and server executable.

Example configuration, with source/prefix paths supplied by the operator:

```sh
cmake -S "$kpipewire_source" -B "$kpipewire_build" \
  -DCMAKE_INSTALL_PREFIX="$kpipewire_prefix" -DBUILD_TESTING=OFF
cmake --build "$kpipewire_build" -j8
cmake --install "$kpipewire_build"
cmake -S "$krdp_source" -B "$krdp_build" \
  -DCMAKE_INSTALL_PREFIX="$krdp_prefix" -DWITH_FREERDP3=ON \
  -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF \
  -DKPipeWire_DIR="$kpipewire_prefix/lib/x86_64-linux-gnu/cmake/KPipeWire"
cmake --build "$krdp_build" -j8
cmake --install "$krdp_build"
```

Run the private **server executable**, with both private library directories
in its `LD_LIBRARY_PATH`. Loading only the library into the old server misses
the pause-signal connection. Include the server prefix's `share` directory in
the compositor's `XDG_DATA_DIRS`: KWin authorizes screencast access against the
executable path in `org.kde.krdp.desktop`. Retain the private KWin library and
capture plugin paths described in the earlier verification.

Both patch chains passed dry runs and reproduced the compiled source files
byte for byte. Both projects built and installed without root. Missing FFmpeg
development headers were downloaded and unpacked into a private dependency
prefix. No system packages, driver, GDM settings, or Remora app source changed.

## Comparable motion measurements

Tests ran on 2026-10-19 on the environment in [verification.md](verification.md):
1280 by 720, the same private KWin/cursor patch, libx264, Remora Debug build,
VideoToolbox decode, and SSH forwarding. The principal before/after runs reused
the same desktop, window placement, background applications, and connection
path. The network was live, not a fixed-latency emulator.

`verification/motion.cpp` paints moving stripes and a 16-bit source counter
based on elapsed time at 60 steps per second. Space restarts a 30-second run.
Remora recording captures the received desktop. `verification/measure-motion.py`
reads the counter from decoded pixels and uses each frame's actual presentation
timestamp. Consecutive repeats count once. The analyzed counter range 180 through
1380 excludes startup and shutdown and covers approximately 20 seconds.
Container FPS is not used as a delivered-motion measurement.

| Run | Distinct updates/s | Mean interval, ms | p95 interval, ms | Gaps over 100 ms |
| --- | ---: | ---: | ---: | ---: |
| Before, run 1 | 18.29 | 54.68 | 95.00 | 13 |
| Before, run 2 | 10.29 | 97.17 | 163.33 | 116 |
| After, run 1 | 35.20 | 28.41 | 51.67 | 0 |
| After, run 2 | 36.24 | 27.59 | 48.33 | 0 |

A subsequent check of the build without instrumentation, on a fresh desktop
with the fixture at a different position, delivered 31.63 distinct updates/s
over 18.12 seconds: mean interval 31.62 ms, p95 50.00 ms, and no gap over
100 ms. This is a deployment check, separate from the matched scene above.

The first baseline and first fixed connection had similar mean send-to-ACK
times, 33.93 and 31.68 ms respectively. The second baseline had a slower mean
of 48.45 ms. These are whole-connection diagnostics, including decode and ACK
handling, not isolated network RTT or physical display latency. The baseline
source cap varied with connection history; the fixed runs retained 60 FPS.
The fixed result is about twice the better baseline, without relying on the
slower baseline for the comparison.

Temporary diagnostics measured encoder-packet enqueue to sender dispatch.
The second baseline connection averaged 29.61 ms, p95 55.20 ms. The first fixed
connection averaged 0.92 ms, p95 2.83 ms. These aggregates include setup/idle
frames and are separate from the 20-second visible-motion measurements.

A second workload dragged the same window horizontally by 200 pixels and back,
ten times, using the same Remora input batch with 1-second drags. Analysis tracks
the first blue stripe on desktop row 600, away from the cursor. It trims two
seconds from each end of the observed motion.

| Window drag | Distinct positions/s | Mean interval, ms | p95 interval, ms | Gaps over 100 ms |
| --- | ---: | ---: | ---: | ---: |
| Before | 14.66 | 68.20 | 133.33 | 36 |
| After | 28.90 | 34.60 | 50.00 | 17 |

Drag intervals include the CLI's intentional pointer-animation/turnaround
waits. They are workload cadence, not a measurement of human pointer latency.
Both runs covered the same measured horizontal position range, 120 through 320.

To reproduce, compile the fixture with Qt 6 Widgets, launch it in the isolated
session, observe it with Remora, then send Space through the CLI and immediately start a recording.
Record at least 25 seconds. Supply the observed window client-area
origin when analyzing:

```sh
c++ -O2 -fPIC verification/motion.cpp -o /tmp/rdpmotion \
  $(pkg-config --cflags --libs Qt6Widgets)
python3 verification/measure-motion.py motion.mov --origin 316 129
python3 verification/measure-motion.py drag.mov --mode drag
```

The drag analyzer assumes a 1280-pixel desktop and visible stripes on row 600.
The barcode analyzer assumes the unscaled 960 by 540 fixture. Adjust placement
or analyzer coordinates before a different layout. Optional per-frame server
logging is added by `verification/instrument-krdp.py SOURCE_DIRECTORY` before
building a disposable measurement prefix. The delivery patches do not contain
that logging.

## Flow-control and compatibility checks

- Blocking downstream delivery for four seconds filled the encoded queue to four packets, triggered encoder pause, and recovered when delivery resumed. No unbounded queue growth occurred in the test.
- Stopping fixture motion while delivery was blocked still delivered the final stationary counter value after recovery.
- Disconnecting with a full ACK window did not hang the sender. A new connection then received desktop frames.
- `verification/ack-suspension.c`, a single-connection `LD_PRELOAD` probe at the FreeRDP server callback boundary, changed ACK 19 into a suspend PDU and withheld subsequent callbacks for three seconds. The client decoded 111 further frames before regular ACK handling resumed at frame 131. This tests server behavior without modifying Remora or shipping the probe.
- Repeated reconnects, Space/Escape input, pointer movement, window dragging, and window-close input worked through the Remora CLI and were checked with screenshots.
- The final private process mapped both patched KWin capture modules, the new KRdp library, and all private KPipeWire libraries. The duplicate-cursor patch and input patch remain intact.
- GDM and GNOME remote desktop remained active on port 3389. NVIDIA remained 615.71.09 on the GTX 1660 Ti. The installed Remora app and global Remora settings were unchanged.

Build the ACK probe against the same FreeRDP server headers:

```sh
cc -shared -fPIC verification/ack-suspension.c -o ack-suspension.so \
  -I"$freerdp_include" -I"$winpr_include" -ldl
```

Set `LD_PRELOAD` only for the isolated test server. The probe uses process-global
callback state and is deliberately limited to one connection. Remove it for
ordinary operation.

Recordings, full logs, decoded-counter data, patch checks, and runtime evidence
are retained outside Git under `.snap/perf-kde/`. They contain no saved
credentials or private keys. The obsolete benchmark desktop and its generated
password/key were removed. The separate demo uses a one-hour launcher and no
per-frame instrumentation or ACK probe.

## Limits

These results show a specific KDE throughput and dispatch-delay improvement.
They do not measure input-to-photon latency or prove GNOME/Windows parity.
Delivered distinct updates remain below 60 per second. Software encoding,
legacy capture/rendering cost, throttling granularity, and client presentation
remain possible contributors; this patch does not assign their individual cost.
NVIDIA encoding still falls back to libx264. Multi-monitor, HDR, transformed
outputs, arbitrary scales, and other clients remain outside this runtime test.
