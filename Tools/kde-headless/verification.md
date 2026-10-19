# KDE headless test fixes

These patches preserve the server changes used to test Remora on Debian 13 with
a headless NVIDIA desktop. They target Debian's KWin 6.3.6-1 and KRdp 6.3.5-1
sources. Remora's build does not apply or bundle them.

The app fix enables network detection, clears disabled multitransport flags,
and builds the fake rdpsnd backend required by FreeRDP's channel dependencies.
It addresses a KRdp handshake failure caused by Remora's inconsistent RDP8
capability negotiation.

## Server patches

| Patch | Purpose |
| --- | --- |
| `patches/kwin-6.3.6-nvidia-egl.patch` | Use explicit EGL modifiers so the virtual backend renders on NVIDIA. |
| `patches/krdp-6.3.5-input.patch` | Authenticate native input, encode Wayland pointer coordinates correctly, and correct FreeRDP 3 key handling. |
| `patches/kwin-6.3.6-cursor-free-screencast.patch` | Render the workspace separately for capture so the virtual output's software cursor does not enter desktop video. |

Apply the KWin patches in the listed order with `patch -p1` from its source
directory. Apply the KRdp patch from its source directory. Build each project
into a private prefix to retain the system desktop packages.

The EGL patch comes from KWin commit
[`60b39e6`](https://github.com/KDE/kwin/commit/60b39e6fdaa8e1c8f54e5c9bc919dae5d6c0cd43).
The capture patch adapts the scene-rendering approach from KWin commits
[`68c41eed`](https://github.com/KDE/kwin/commit/68c41eed7df7d13e3e7881e807680683c6c40456),
[`f9d854bc`](https://github.com/KDE/kwin/commit/f9d854bc629e3f682d848f7d15cd362436bb2e6b), and
[`85c9a58e`](https://github.com/KDE/kwin/commit/85c9a58e15729f5be0eaf66705d620693f95cf83)
to the 6.3 scene API. It is an adaptation, not a direct cherry-pick. KDE describes
the virtual-output cursor defect in
[bug 512622](https://bugs.kde.org/show_bug.cgi?id=512622#c4).

## Verified environment

- Debian 13, Plasma 6.3.6, KRdp 6.3.5, KPipeWire 6.3.6, and FreeRDP 3.15.0 on the server.
- Qt 6.8.2, KDE Frameworks 6.13.0, and PipeWire 1.4.2.
- NVIDIA GTX 1660 Ti with driver 615.71.09 and OpenGL compositing.
- Private Wayland desktop at 1280 by 720, with KRdp's native `--plasma --monitor 0` capture path.
- GDM and GNOME remote login retained on port 3389; private KRdp bound to loopback port 3392.
- FreeRDP 3.32.2 and FFmpeg VideoToolbox decoding in the tested Remora build.

Both the private `libkwin` and its `screencast` plugin must be loaded. The plugin
directory used by this build is `lib/x86_64-linux-gnu/plugins` inside its prefix.
Loading a private executable with the system capture plugin does not test the fix.

## Verification performed

- Rebuilt the Remora engine with `Vendor/build-engine.sh`.
- Built the Debug app with `xcodebuild -project Remora.xcodeproj -scheme Remora -configuration Debug -derivedDataPath build/KRdpFix build`.
- Passed all 66 package tests across RemoraCore and RemoraControl.
- Connected and reconnected to KRdp with H.264 frames decoded through VideoToolbox.
- Connected to GNOME and Windows, received frames, and verified visible input responses after the app change.
- Used the `remora` CLI to launch Kate, click, type, and drag-select text on KDE.
- Compared raw screenshots before and after the capture patch: the server cursor pixels disappeared.
- Verified that separate arrow and I-beam images and hotspots still reached the client.
- Recorded motion with cursor overlays on and off: one cursor when enabled, no cursor when disabled.
- Confirmed the cursor fix with the user's own mouse after reconnecting the app.

## Remaining work

The setup is temporary and has no login or reboot service. Global KDE shortcuts
are disabled in the isolated launcher. The capture backport renders a complete
output scene; sustained performance has not been benchmarked. The user reports
that KDE remains less smooth than GNOME and Windows.

Runtime checks covered KRdp's workspace capture on one NVIDIA virtual output.
The output-capture path compiled but was not tested separately. Multi-monitor
capture, HDR, rotated outputs, and all native viewport scales remain unverified.
Server encoding currently falls back to CPU libx264; GPU desktop rendering does
not establish that video encoding uses the GPU.
