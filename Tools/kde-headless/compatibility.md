# KDE compatibility checks

Run these checks through Remora after changing the app, server, capture library,
or desktop launcher. A successful connection proves only that the desktop stream
started. Mark each behavior passed, failed, unsupported, or not tested. Keep the
server and client versions with the result. Repeat failed cases after a fix.

## Current results

Checked on 2026-10-19 using the private Debian 13 setup described in
[verification.md](verification.md), at 1920 by 1080. These results cover the
fixed Remora Debug build and KRdp's native Plasma backend. They do not establish
support for every Plasma installation or RDP feature.

| Behavior | Result | Evidence or limit |
| --- | --- | --- |
| Connection and desktop pixels | Passed | Remora reports and captures 1920 by 1080. |
| Cursor shape and position | Passed previously | User confirmed the cursor fix; see verification.md. |
| Text entry and punctuation | Passed | Fixture displays `Remora keyboard 123 !@#`. |
| Select, delete, undo | Passed | Ctrl+A, Backspace, Ctrl+Z restores the fixture text. |
| Left, right, middle clicks | Passed | Fixture receives button values 1, 2, 4 and release events. |
| Pointer dragging | Passed | Fixture reports a 200-pixel horizontal drag. |
| Vertical scrolling | Passed after patch | Firefox visibly scrolls down and back up. |
| Horizontal and fractional scrolling | Passed after patch | Half-notch input on each axis reaches the fixture; opposite input balances the counters. |
| Text clipboard, both directions | Passed after backport | Unicode pasted through Ctrl+V; the fixture's Copy button returns the exact Unicode sample through RDP. |
| Empty and multiline clipboard | Passed after backport | Empty text clears the field; native Wayland and RDP checks preserve multiline Unicode and its trailing newline. |
| Reconnect | Passed with clipboard backport | The fixture survives; clipboard works both ways after reconnect. |
| Sustained motion and recovery | Passed within measured limits | See smoothness-verification.md; performance remains below 60 updates/s. |
| 4K desktop | Passed previously for display only | Actual 3840 by 2160 frame captured; 4K motion was not measured. |
| Global desktop shortcuts | Passed for Alt+F4 | Removed the launcher's `--no-global-shortcuts` restriction; Alt+F4 closes the fixture. Other global shortcuts remain untested. |
| Back/Forward mouse buttons | Unsupported by native server backend | InputHandler accepts them, but PlasmaScreencastV1Session rejects those buttons. |
| Lock-key state synchronization | Unsupported by server | InputHandler::synchronizeEvent is a no-op. |
| Audio forwarding | Unsupported by server | KRdp 6.3.5 disables audio playback. |
| Image, HTML, file clipboard | Unsupported by proposed text backport | Unicode text is the supported clipboard format. |
| Multi-monitor, HDR, arbitrary scaling | Not tested | A single unscaled virtual output was used. |
| Long session, host reboot, Mac sleep/wake | Not tested | The desktop and SSH tunnel remain temporary. |

## Repeating the input checks

Build [verification/desktop-input.cpp](verification/desktop-input.cpp) with Qt 6
Widgets and launch it in the isolated desktop's Wayland and D-Bus environment.
Launching it does not verify RDP input. Operate it using Remora and inspect a
fresh remote screenshot after each action.

1. Type the sample text. Select all, delete, undo, and verify the restored text.
2. Click the pointer target with each supported button. Drag by a known distance
   and verify the reported release and distance. Double-click text and verify
   word selection.
3. Scroll the target by half a notch on both axes, then reverse both. Verify the
   received angle deltas and balanced totals. Scroll the lower text area in both
   directions on each axis and verify its contents and scrollbars move.
4. Offer known text using `remora clipboard set`, paste into the text field with
   Ctrl+V, and verify it. Press the fixture's Copy button and compare
   `remora clipboard get` with the exact Unicode sample. Repeat with empty text,
   multiline text, a replacement value, and after reconnect. These CLI operations
   test RDP clipboard transport without reading the Mac clipboard. Human
   copy-paste and macOS pasteboard permissions require a separate check.
5. Disconnect and reconnect. Repeat text, pointer, scroll, and clipboard checks.
6. Repeat the motion workload and recovery scenarios in
   [smoothness-verification.md](smoothness-verification.md).

Use synthetic clipboard contents. Preserve screenshots and command results
outside Git; do not archive credentials or private clipboard data.

## Scroll correction

Apply `patches/krdp-6.3.5-scroll.patch` after the existing KRdp input and flow
patches. Rebuild and restart the private server. The patch changes only the
native Plasma input adapter.

The old adapter divides angle deltas by 120 using integer arithmetic, then
passes that integer where the generated Wayland API expects `wl_fixed_t`.
Small deltas become zero; larger values become tiny scroll distances. The patch
preserves fractions and encodes the fixed-point wire value. It maps a 120-unit
notch to 10 axis units, matching the axis-only fallback in
[Qt Wayland 6.8.2](https://github.com/qt/qtwayland/blob/v6.8.2/src/client/qwaylandinputdevice.cpp).
This protocol has no discrete-wheel request, so exact scroll distance in other
toolkits remains toolkit-dependent.

## Text clipboard backport

Apply `patches/krdp-6.3.5-clipboard.patch` after the other KRdp patches. It adds
the existing KF6 GuiAddons dependency and uses KSystemClipboard for native
Wayland clipboard access. Build into a private prefix and run its server with
the corrected KPipeWire libraries. Include its `share` directory in the desktop's
`XDG_DATA_DIRS` so KWin can authorize the server executable.

The patch adapts upstream clipboard changes through
[`28a362a2`](https://invent.kde.org/plasma/krdp/-/commit/28a362a2281928153b5e05b7aa5d2a86d1996efb),
including native-session wiring, ownership, interoperability, and readiness
fixes. The callback adapter queues owned packet data onto the Qt thread instead
of blocking a FreeRDP callback while the main thread can be waiting for shutdown.
Channel sends and close are serialized. UTF-16LE, CRLF conversion, empty text,
non-text formats, and responses to replaced selections are handled explicitly.
This is an adaptation, not an unmodified upstream cherry-pick.

The offline check links the built Clipboard implementation and replaces the
FreeRDP boundary. It tests known wire bytes, readiness, empty and non-text
formats, copied callback packet lifetimes, stale responses, teardown, and fresh
connection state. It does not access a desktop or prove RDP interoperability.
The runtime checks in the table provide that separate evidence.

```sh
cmake -S verification/clipboard -B /tmp/krdp-clipboard-check \
  -DKRDP_SOURCE_DIR="$krdp_source" -DKRDP_BUILD_DIR="$krdp_build" \
  -DKPipeWire_DIR="$kpipewire_prefix/lib/x86_64-linux-gnu/cmake/KPipeWire"
cmake --build /tmp/krdp-clipboard-check
/tmp/krdp-clipboard-check/clipboard-check
```
