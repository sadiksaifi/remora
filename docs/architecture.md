# Architecture

Remora is a native macOS remote desktop client. V1 speaks RDP through FreeRDP 3.x. VNC comes later behind the same session interface.

This is personal software. Prefer an existing library or a FreeRDP built-in over writing our own. Write code only where nothing suitable exists.

## Platform

- macOS 26.0 and later, arm64 only.
- Swift 6 language mode with complete strict concurrency.
- AppKit for the window, menus, the connection list, and the session view. SwiftUI in `NSHostingController` or `NSHostingView` for sheets, Settings, session status views, and the tab strip.
- Apple's macOS 27 Human Interface Guidelines are the design baseline. Liquid Glass comes from standard AppKit and SwiftUI controls and the SwiftUI glass effect.
- The renderer and shortcut-capture demo harnesses compile only in Debug builds.
- No App Sandbox. Hardened runtime only when we notarize a release.

## Layout

```
Remora.xcodeproj           app target, synchronized folders
Remora/                    AppKit app, SwiftUI sheets, Metal renderer
Packages/RemoraKit/
  RemoraCore               session protocol, connection model, connection store, credentials, neutral input
  CFreeRDPBridge           plain C bridge; the only code that includes FreeRDP headers
  RDPSession               Swift RDP adapter implementing the session protocol
Vendor/build-engine.sh     builds OpenSSL, FreeRDP, and FFmpeg into an arm64 static XCFramework
```

## Window and tabs

Remora has one main window. Its home page is the connections list. Each open session is a tab in the same window. Native window tabbing is off (`tabbingMode = .disallowed`), because native tabs are separate windows and window managers such as AeroSpace, yabai, and Rectangle would see one window per session.

- `SessionTabs` owns the tabs: one per connection, in opening order, with the selection (nil for home) and each tab's session state. The connections list, the tab strip, the toolbar, and the Window menu observe it.
- `SessionViewController` is one tab's page. It owns the session, its renderer and desktop view, the overlays, the clipboard sync, and its credentials and certificate sheets.
- `MainWindowController` shows the selected page, owns the toolbar, and routes the Session and tab menu actions to the shown tab.

The toolbar shows the title "Connections", the + button, and search while no tab is open. With tabs open, the title hides, a Home button follows the traffic lights, and the tabs sit between two flexible spaces. The toolbar draws its glass capsule around the tab strip, centers it, and lets it grow to its ideal width (220 points per tab). Past that the tabs share the available width and finally scroll. Tab contents follow Safari's compact tabs. The title is centered, with the status dot to its left. While the pointer is over a tab, a close button (`xmark.circle.fill`) shows at its left end. The shown tab has a Tab Actions button (`line.3.horizontal`) at its right end, and the keyboard capture toggle just left of it, where Safari puts its reload button. Both stay visible on the shown tab without hover. The title's side padding is the same on both sides, so the title stays centered and truncates between the controls: 46 points while the keyboard toggle shows, otherwise 24. Tabs share the width equally, but the shown tab keeps at least 132 points, taken from the other tabs down to their 76-point minimum. When the strip is too narrow even for that, the shown tab hides the keyboard toggle, and the menu's Capture Keyboard item covers it. The actions button hangs the tab's menu under it: Capture Keyboard with a checkmark, a separator, Take Screenshot, Copy Screenshot, and the recording item with their shortcuts, a separator, then the tab context menu's items, ending with Close Tab. AppKit has no public menu with Safari's arrow, so it is a plain pop-up menu centered under the button. Secondary-clicking a tab shows the context menu, which has the same items without the first two groups. `MainWindowController.tabMenu(for:includingActions:)` builds both, and `makeCaptureItems()` builds the capture items for this menu and the Session menu. The tab's accessibility element sorts first, then VoiceOver reaches the keyboard toggle and a "Tab Actions" button (identifier `tabActions`) as their own elements. Closing stays a "Close Tab" action on the tab. The search item collapses to a button through a low-priority width on its field. On home it filters the list; on a tab it offers saved connections through `NSTextField.suggestionsDelegate`. On a tab, Escape works like a native search field: the first press closes the suggestions, and the next clears and closes the search and gives the keyboard back to the desktop.

A hidden tab's desktop leaves the window. Its display link stops, so it presents no frames, and its keys, buttons, and keyboard capture are released. Its session stays connected and asks the server to stop sending desktop updates. `SessionDisplay` does the same while the window is minimized or fully covered (`NSWindow.occlusionState`). Showing the tab redraws the last frame at once, turns updates back on with a refresh of the whole desktop, and requests the current size for Fit to Window. A credentials or certificate request on a hidden tab marks the tab with an orange dot and waits; its sheet appears when the tab shows. Tabs can't change while the window has a sheet.

Closing a tab disconnects its session. Closing the window asks first while any session is live, then closes every tab.

## Session interface

One Swift protocol in RemoraCore. The app never sees FreeRDP types.

- Commands in: connect, disconnect, key, pointer, wheel, request resize, display updates on or off, local clipboard text.
- Events out: state (connecting, awaiting credentials, awaiting trust, connected, reconnecting, disconnected with a typed reason), desktop size, cursor, remote clipboard text.
- Frames go to an injected frame sink, not through the event stream.
- A resize request is not a size change. Only the desktop size event resizes the renderer.

## Threading

- Each session owns one dedicated thread. It runs `freerdp_connect`, the event loop, and every FreeRDP call.
- Input, resize, display update, clipboard, and disconnect commands go through a locked queue plus a wake event in the event loop's wait set.
- Display updates use Suppress Output (MS-RDPBCGR 2.2.11.3). Turning them back on also sends Refresh Rect for the whole desktop. FreeRDP sends neither PDU to a server that doesn't advertise support, and that server keeps sending updates. A reconnected server starts with updates on, so the bridge sends the current choice again.
- `freerdp_abort_connect_context` is the only cross-thread FreeRDP call.
- FreeRDP callbacks arrive on several threads (GFX and Display Control on the dynamic channel thread, clipboard on its own). The bridge copies data upward and never assumes a thread.
- Credential and trust callbacks block the session thread on a condition variable until the MainActor answers.
- Frame pixels are borrowed for the duration of the frame callback only. FreeRDP replaces the buffer on resize.

## Rendering

`CAMetalLayer` with one private BGRA texture. The renderer copies dirty rectangles into shared staging buffers, then blits the accumulated damage and draws one opaque quad in the same command buffer. Semaphores prevent CPU writes while the GPU reads a staging buffer. `NSView.displayLink` paces presentation, with at most one command buffer in flight. Pending damage coalesces instead of queueing frames; an idle desktop submits no GPU work. Pixels are tagged sRGB. Scaling uses aspect fit with black letterboxing, nearest sampling at 1:1, and linear sampling otherwise.

## Desktop sizing

Connections default to Fit to Window, including saved connections without a resolution key. Fit to Window connects at the tab's content size in backing pixels and announces the display's backing scale. Display Control follows window resizing, screen changes, full-screen transitions, and the tab showing again.

A fixed resolution stores a width and height in remote pixels in RemoraCore. Each side must be 200 to 8192 pixels, and the width must be even. Fixed sessions connect with those dimensions and scale 1 (DesktopScaleFactor and DeviceScaleFactor 100). The RDP adapter rejects resize requests and disables Display Control negotiation for their lifetime, including automatic reconnect and GNOME's redirected reconnect through FreeRDP's original settings backup.

The window never resizes for a session. Fixed sessions and unrequested server desktop sizes render with aspect fit and letterboxing in the tab's content area below the toolbar. Fit to Window follows that area's size. In full screen the toolbar hides until the pointer reaches the top, and Fit to Window requests the screen size. The renderer and pointer mapping share `DesktopGeometry`; letterbox bars do not send pointer input.

## Input

- The session view is first responder and handles `keyDown`, `keyUp`, `flagsChanged`, and `performKeyEquivalent`.
- Key events carry the macOS virtual key code. RDP maps it with WinPR's Apple keycode table to scancodes.
- Physical mapping: Command is Windows/Super, Control is Control, Option is Alt.
- The keyboard layout announced to the server follows the current Mac input source.
- All pressed keys and buttons are released when the window loses key status, the app deactivates, or the tab hides. Modifiers still held when the key state resets stay out of the remote state until released.
- Scroll accumulates into 1/120-notch wheel units.
- System shortcuts (Cmd-Tab, Cmd-Space) are captured with a `CGEventTap` while a session tab shows, its desktop has the keyboard, and the window is key. This needs the Accessibility permission. Without it, or with capture turned off in Settings, those shortcuts stay local.
- Cmd-Q and Ctrl-Cmd-F always stay local, and so does the Ctrl-Option-Cmd family: `[` and `]` for the previous and next tab, 1 through 9 for tab N, H for the connections list, W to close the tab, S to save a screenshot, Shift-S to copy one, R to start or stop recording, and Escape to release the keyboard, like Session > Release Keyboard Capture. Clicking the desktop captures the keyboard again. Ctrl-Option-Cmd-arrows are left to window managers such as Rectangle. Other menu shortcuts, including Cmd-W, act only while the desktop does not have the keyboard.
- Session > Send Ctrl-Alt-Delete sends Control, Option, and Forward Delete through the ordinary key path.
- A keyboard capture toggle on the shown tab shows whether its desktop has the keyboard: it is first responder of the key window, the app is active, and the session is connected. `SessionTabs.Tab.isKeyboardCaptured` carries that state, and the tab view reads it directly. System shortcut capture follows the same state. The toggle shows a filled, accent-colored keyboard symbol while captured and an outlined secondary one otherwise, and clicking it captures or releases the keyboard. It is disabled without a connected session, and unselected tabs and Home have none. The tab actions menu's Capture Keyboard item does the same and shows a checkmark while captured. It is a SwiftUI `Toggle` with the button style, so accessibility reports a check box with the identifier `keyboardCapture`, the description "Keyboard Capture", value 1 while captured, and the tooltip as its help. The window toolbar has no keyboard control.

## Codecs

- Progressive RemoteFX, AVC420, and AVC444 are enabled explicitly. FreeRDP's library defaults leave them off.
- H.264 decodes through FFmpeg with VideoToolbox acceleration and FFmpeg software fallback.

## Storage

- Saved connections: a JSON file in Application Support.
- Passwords: Keychain via KeychainAccess, keyed by connection ID.
- Certificates: FreeRDP's own certificate store, with `ConfigPath` inside Application Support. Remora shows the trust dialog.

## License

GPL-3.0-or-later. Every dependency is compatible, and it keeps LibVNCClient available for the VNC phase. Distribution is outside the Mac App Store.

## Session capture

`SessionViewController.capture: SessionCapture` owns capture for one tab. `SessionCapture` is a main-actor observable object in RemoraCore. It takes constructor-injected `CaptureMedia` and `CaptureDestination` adapters. `AppleCaptureMedia` contains ImageIO, AVFoundation, Core Image, and VideoToolbox calls. `ScreenshotDestination` contains macOS location and filename policy. The app UI is described under "Capture UI" below.

The UI entry points on `SessionViewController` are:

```swift
let capture: SessionCapture
func takeScreenshot(copyToClipboard: Bool = false) async throws -> URL?
func startRecording() throws
@discardableResult
func stopRecording() async -> Result<URL, CaptureFailure>?
```

`takeScreenshot(copyToClipboard: false)` saves a PNG and returns its URL. Passing true puts the same PNG representation on `NSPasteboard.general` and returns nil. The clipboard operation lives in the AppKit controller. The portable capture object also exposes `screenshotPNG() async throws -> Data` and `saveScreenshot(connectionName:) async throws -> URL`.

Observe these properties on `capture`:

```swift
public private(set) var recordingState: RecordingState
public private(set) var lastSavedURL: URL?
public private(set) var recordingURL: URL?

public enum RecordingState: Sendable, Equatable {
    case idle
    case recording(startedAt: TimeInterval)
    case finishing
    case failed(CaptureFailure)
    public func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval?
}
```

The start time uses monotonic uptime, not a calendar date. The UI can use a timeline to show elapsed seconds without asking the encoder for updates. `lastSavedURL` changes only after a successful save or movie finalization. `recordingURL` identifies the reserved output while recording or finishing. Stop returns nil if no recording needs finishing. Concurrent stop callers await the same task. Starting before the first frame throws `CaptureFailure.noFrame`. Starting during recording or finishing throws `.busy`. Other failures use `.image(String)`, `.recording(String)`, `.file(String)`, or `.timedOut`, with localized descriptions. An encoder failure changes state to failed after the same stop path cleans up. Failure observation uses AVAssetWriter status observation and a bounded async stream, with no idle polling timer.

`MetalDesktop` owns the renderer's existing three staging slots, exact damage union, private BGRA texture, and serial command queue. `FrameRenderer` owns presentation and its display pipeline, and implements `FrameSink` directly. There is no capture fan-out and no separate CPU framebuffer. The ordinary session path still copies only dirty rectangles into the original staging slots. Capture adds a nil observer and one arrival timestamp to that state. With recording off, the only ingest-path difference is the nil check inside the existing lock. There is no capture copy, allocation, clock read, dispatch, timer, readback, or additional lock on the RDP thread. The previous dirty-rectangle mapping into a second app-specific array is also removed.

Screenshots use a one-time readback of that native-resolution texture. This is smaller than a new protocol framebuffer operation: the renderer already owns the complete desktop and the ordering needed to read it, so there is no new FreeRDP command, worker lock, callback lifetime, or VNC-specific implementation. `SessionCapture.screenshotPNG()` runs readback and ImageIO encoding off the main actor. Readback flushes any pending dirty uploads before copying the whole texture into a temporary shared Metal buffer. It waits for that command outside the ingest lock, then copies into the owned `CaptureFrame` used by ImageIO. Both temporary pixel buffers disappear after the operation. No new remote frame, display link, drawable, visible tab, or Screen Recording permission is needed. The image contains no Mac toolbar, window decorations, overlays, or local cursor.

The UI entry points, recording states, elapsed-time API, and saved URLs above are unchanged. The internal adapter interface changed: `CaptureFrameSink`, `SessionCapture.frames`, and the `frames:` initializer parameter were removed. `SessionCapture.setSource(_:)` attaches a `CaptureSource` when a renderer is created and detaches it when the session ends. `CaptureSource` exposes `size`, `snapshot()`, and `setFrameObserver(_:)`. `CaptureMedia.movie(at:source:)` replaces `movie(at:initialFrame:)`. `CaptureMovie.submit(arrival:)` replaces `submit(_ frame:)`. The Apple movie adapter consumes `MetalDesktop`; VNC can use the same renderer without any capture changes. Old session callbacks have their own old renderer, so they cannot update a replacement session's source.

A recording begins with the current complete desktop. It uses AVAssetWriter, a video-only QuickTime movie, and HEVC. The top-level `AVVideoEncoderSpecificationKey` sets `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` to true. Hardware unavailability fails instead of falling back to software. The bit rate is four bits per desktop pixel per second, bounded to 2 to 40 Mbps. That gives about 8.3 Mbps at 1920 by 1080 and 33.2 Mbps at 3840 by 2160, retaining screen detail without allocating a high-motion camera bit rate to an idle desktop. Keyframes are at most two seconds apart. Frame reordering is disabled to reduce encoder buffering. Output color metadata is Rec. 709.

The movie adapter gets BGRA IOSurface-backed, Metal-compatible buffers exclusively from the adaptor's pool. A six-buffer allocation threshold bounds pool growth. While recording, a lightweight observer announces frame arrival after the renderer's original dirty copy. The one-element mailbox holds only the latest arrival time, not pixels. The utility worker flushes accumulated dirty uploads to the existing desktop texture, then GPU-copies that texture directly into a pool buffer. The RDP thread performs no extra recording pixel copy and never waits for an encoder operation. Matching dimensions use a Metal blit. Core Image is created only after a size change, to aspect-fit the texture over opaque black within the initial recording dimensions. A same-format texture view forces alpha to one for Core Image sampling, because the protocol's alpha byte is undefined. The writer and track dimensions remain fixed. Core Image's intermediate cache is disabled.

Presentation, screenshots, and recording reserve command queue order under the renderer's existing lock with `enqueue()`. Encoding the rest of a command, compiling Core Image kernels, waiting for GPU completion, allocating encoder buffers, and appending to AVAssetWriter all happen outside that lock. Every enqueued command is committed even if its consumer throws. Each taken staging slot is returned exactly once by command completion, or by dropping a still-pending upload. There is no second capture semaphore. Core Video texture wrappers stay alive until their GPU copy completes, and ARC owns the pool buffers and framework objects.

The arrival clock is process uptime, read only while the recording observer is installed. Presentation timestamps use the arrival of the texture version actually copied, relative to recording start, with the first sample at zero and a minimum interval of 1/60 second. The worker coalesces faster arrivals to the latest timestamp. When the input is not ready or the pool reaches its threshold, it retains that single pending timestamp and retries after 1/60 second. Retries stop when there is no pending change. A static desktop submits no periodic frames. Finalization retains the last immutable pool buffer and appends it once at the stop timestamp, then ends the writer session at that same timestamp. This extends the encoded media through the final idle interval, including a recording with only one source frame. Ending the session alone extends AVFoundation's edit-list timing but can leave the actual media shorter, which other players report as truncated. Stop time is captured once on entry to movie finalization using the same uptime origin as frame timestamps. Stop, close, disconnect, and quit use that path, and a failed final append uses the ordinary typed failure and cleanup path.

The incremental idle capture storage is the optional observer and arrival metadata, plus the session's source reference. There is no desktop-sized capture allocation. Recording adds the bounded encoder pool, texture cache, and one pending timestamp. At equal dimensions it adds one full GPU texture-to-pool blit per encoded frame, at most 60 per second, with no full CPU copy or Core Image pass. At 3024 by 1964 each blit transfers 23,756,544 bytes, about 1.43 GB/s of GPU copy traffic at the cap. The renderer's normal dirty uploads remain shared with display. No new live profile was taken; these are code-path and byte-count costs, not measured CPU percentages.

Recording forces `SessionDisplay` updates on, including hidden tabs, minimized windows, and occluded windows. Stop removes that override and applies the current visibility state. Automatic RDP reconnect keeps the capture object, movie, timeline, and update override. Frames resume in the same movie after reconnect, with any new desktop size fitted into the original video size. Terminal disconnect finishes the movie. A later manual connection attempt attaches a new renderer with no old desktop texture.

Stop, explicit disconnect, terminal session end, and controller teardown remove the renderer's recording observer before finishing the movie. Tab close and window close use the same controller disconnect path. `SessionTabs` retains captures from closed tabs until they finish, so quitting also waits for movies whose tabs have already disappeared. `AppDelegate.applicationShouldTerminate(_:)` disconnects sessions, returns `.terminateLater`, waits for all captures, and calls `reply(toApplicationShouldTerminate:)`. A pending frame has five seconds to drain. Movie finalization has an eight-second cancellation deadline. The app has a ten-second overall deadline and logs any unfinished destination and partial-file location before replying. Force Quit, process crashes, and power loss cannot run this teardown.

`ScreenshotDestination` reads `com.apple.screencapture` `location`, expands a tilde, and otherwise uses `~/Desktop`. An explicitly configured location that cannot be written produces a typed error rather than silently saving somewhere else. Names use local time, for example `Remora - Office - 2026-10-18 at 03.40.12.png` or `.mov`. Unsafe filename characters are replaced with hyphens. An exclusive file creation reserves the name; collisions add ` (2)`, ` (3)`, and so on. Movie encoding uses a unique hidden `.Remora-<UUID>.partial.mov` in that folder while the destination stays reserved. Successful finish atomically replaces that empty reservation. Failed writes delete the reservation and partial movie. A cleanup error reports the remaining path.

### Capture UI

The Session menu has Take Screenshot (Ctrl-Option-Cmd-S), Copy Screenshot (Ctrl-Option-Cmd-Shift-S), and Start Recording (Ctrl-Option-Cmd-R). The screenshot items are enabled only on a connected session tab. Menu validation retitles the recording item from the shown tab's `capture.recordingState`: Start Recording on a connected tab, Stop Recording while recording, and a disabled Finishing Recording... while the movie finalizes. Copy Screenshot is a visible item rather than an Option alternate, because an alternate of a four-modifier shortcut shows only while all four keys are held, and HIG asks not to hide a primary action behind an alternate. The three shortcuts are in `SystemShortcutCapture.staysLocal`, so they work while the desktop has the keyboard. The shown tab's actions menu has the same three items. Each names its tab through `representedObject`, and the actions and validation use that tab's session.

Each tab that records shows a red `record.circle` symbol in place of the status dot, to the left of its title, including hidden tabs. Recording needs a connected session, so the green dot it replaces carries no information. `SessionTabView` reads `tabs.session(for: id)?.capture` in its body, so SwiftUI observation updates it directly. The symbol differs from the status dot in shape and color: the dot is a solid 7-point circle in green, orange, or gray. Like Safari's audio button in a tab, clicking the symbol stops that tab's recording. While the movie finalizes, the symbol is dimmed and disabled. Its tooltip gives the elapsed time, computed from `RecordingState.elapsed(at:)` when the body evaluates; hovering the symbol reevaluates it, so there is no timer or redraw loop. Accessibility adds "recording" or "finishing recording" to the tab's value and a Stop Recording action. The toolbar has no recording control: the tab strip already covers every tab, and a toolbar item would show only the shown tab.

A saved or copied screenshot shows "Screenshot Saved" or "Screenshot Copied" in a small glass capsule at the bottom of the desktop for 1.5 seconds, then fades out. It ignores the pointer and is not part of any capture, because captures read the renderer texture. It plays the system Screen Capture sound unless the user turned off user interface sound effects (`com.apple.sound.uiaudio.enabled`), and posts an accessibility announcement. No notification permission is needed.

A start or screenshot failure shows a "Capture Failed" warning sheet with the failure's localized description. Every stop path ends in `onRecordingActivityChange(false)`, which awaits the shared stop result once, so user stop, encoder failure, and disconnect report a failure exactly once. When cleanup cannot remove a reserved or partial file, the core's description names its path, so the sheet shows it. A failure on a hidden tab marks it with the orange dot and shows when the tab shows. It waits in its own slot, so it never replaces a pending credentials or certificate request; AppKit shows the second sheet after the first ends.

When any tab records or finishes a recording, the window close sheet adds "Recordings in progress are saved." Quit shows no capture UI and is bounded by the ten-second finalization deadline above.

### Verification and remaining work

`swift test --package-path Packages/RemoraKit` runs the existing tests and two capture tests. The screenshot test uploads a padded synthetic desktop, destroys the borrowed storage, and reads back without a drawable, presentation, recording observer, or new frame callback. It checks all decoded PNG pixels and dimensions. A later one-pixel update copies exactly four bytes and preserves the rest of the idle desktop. A deliberately throwing command consumer also verifies that an enqueued upload still completes and releases its staging slot. The movie test records synthetic desktops, changes aspect ratio, submits a burst faster than 60 fps, waits through an idle interval, finishes, and reads the resulting movie. It checks playability, HEVC, fixed dimensions, no audio, duration, sample spacing, decoded black letterboxing, resized desktop color, and vertical orientation with undefined source alpha. Synthetic movie files are temporary and removed by the test.

Automatic lifecycle failures are also written to the session log. On-screen verification, real reconnect, encoder saturation, disk-full failure, and quit with a live remote session have not been exercised by these automated tests.

The on-screen verifier should use only a development instance it launches itself. It must leave the user's installed `/Applications/Remora.app` and other instances alone. Do not use Penguin, type passwords, modify saved connections or Keychain entries, or back up or restore the user's live `connections.json`. Use only the saved Windows connection `desktop-b8l68ps.tail5b813.ts.net` and only look at its desktop. Keep remote captures under `/Users/sdk/Projects/Remora/.snap/`; remove any test captures saved into the configured screenshot location.

- Verify save and clipboard screenshots after the desktop becomes idle. Compare native dimensions and the whole image, excluding the Mac toolbar, tab strip, and overlays.
- Verify a second save in the same second does not overwrite the first.
- Start recording, switch to home or another tab, and confirm the movie continues receiving desktop changes. Stop while hidden and confirm visibility-based suppression resumes.
- Resize a Fit to Window session during recording. Check fixed movie dimensions, preserved aspect ratio, and black bars.
- Check that idle time remains in the movie duration and playback seeks correctly.
- Exercise automatic reconnect while recording, then verify one playable file with the reconnect interval and resumed desktop frames.
- Separately test stop, tab close, Disconnect, terminal session end, window close through the Disconnect sheet, and normal app quit. Open every resulting movie after finalization.
- Check the observable finishing and failed states through the completed UI, including a destination that cannot be written. Confirm the app reports failures and no unexplained partial file remains.
