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

The toolbar shows the title "Connections", the + button, and search while no tab is open. With tabs open, the title hides, a Home button follows the traffic lights, and the tabs sit between two flexible spaces. The toolbar draws its glass capsule around the tab strip, centers it, and lets it grow to its ideal width (220 points per tab). Past that the tabs share the available width and finally scroll. The search item collapses to a button through a low-priority width on its field. On home it filters the list; on a tab it offers saved connections through `NSTextField.suggestionsDelegate`. On a tab, Escape works like a native search field: the first press closes the suggestions, and the next clears and closes the search and gives the keyboard back to the desktop.

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
- Cmd-Q and Ctrl-Cmd-F always stay local, and so does the Ctrl-Option-Cmd family: `[` and `]` for the previous and next tab, 1 through 9 for tab N, H for the connections list, W to close the tab, and Escape to release the keyboard, like Session > Release Keyboard Capture. Clicking the desktop captures the keyboard again. Ctrl-Option-Cmd-arrows are left to window managers such as Rectangle. Other menu shortcuts, including Cmd-W, act only while the desktop does not have the keyboard.
- Session > Send Ctrl-Alt-Delete sends Control, Option, and Forward Delete through the ordinary key path.
- A Keyboard Capture toggle in the toolbar shows whether the shown tab's desktop has the keyboard: it is first responder of the key window, the app is active, and the session is connected. System shortcut capture follows the same state. The toggle turns on with a filled, accent-colored keyboard symbol, and clicking it captures or releases the keyboard. It stays in the toolbar while any tab is open, disabled without a connected session, so the tab strip doesn't move between pages. Accessibility reports it as a check box with the identifier `keyboardCapture`, the description "Keyboard Capture", value 1 while captured, and the tooltip as its help.

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

`SessionViewController.capture: SessionCapture` owns capture for one tab. `SessionCapture` is a main-actor observable object in RemoraCore. It takes constructor-injected `CaptureMedia` and `CaptureDestination` adapters. `AppleCaptureMedia` contains ImageIO, AVFoundation, Core Image, and VideoToolbox calls. `ScreenshotDestination` contains macOS location and filename policy. There are no new menu items, shortcuts, indicators, sheets, or other capture UI in the core implementation.

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

The existing `RendererFrameSink.consume(_:)` fans each borrowed desktop frame to capture and rendering. `CaptureFrameSink` copies every row into one tightly packed owned BGRA buffer before returning. It ignores source alpha and dirty rectangle boundaries. This preserves the complete native-resolution desktop for screenshots even after the borrowed storage is overwritten and while the remote desktop is idle. Frames contain no AppKit toolbar, window decorations, overlays, or local cursor. Protocol cursor events are separate from desktop pixels. No FreeRDP API is involved. Each session attempt gets a source from `makeSource()`. Clearing retires that source so a late callback from an old attempt cannot replace a new session's desktop.

A recording begins with the current complete desktop. It uses AVAssetWriter, a video-only QuickTime movie, and HEVC. The top-level `AVVideoEncoderSpecificationKey` sets `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` to true. Hardware unavailability fails instead of falling back to software. The bit rate is four bits per desktop pixel per second, bounded to 2 to 40 Mbps. That gives about 8.3 Mbps at 1920 by 1080 and 33.2 Mbps at 3840 by 2160, retaining screen detail without allocating a high-motion camera bit rate to an idle desktop. Keyframes are at most two seconds apart. Frame reordering is disabled to reduce encoder buffering. Output color metadata is Rec. 709.

The movie adapter gets BGRA IOSurface-backed, Metal-compatible buffers exclusively from the adaptor's pool. A six-buffer allocation threshold bounds pool growth. Core Image aspect-fits the native desktop into the initial recording dimensions, compositing over opaque black. A size change never recreates the writer or changes the track size. Core Image's intermediate cache is disabled. ARC owns buffers, images, observations, and framework objects; there is no manually transferred renderer resource or semaphore in capture.

The arrival clock is process uptime. Presentation timestamps are relative to recording start, with the initial snapshot at zero and a minimum interval of 1/60 second. The worker coalesces faster arrivals to the latest frame. A single locked mailbox holds the pending frame, sharing immutable Data with the current desktop snapshot. There is no frame queue. Encoding and pixel-buffer allocation run on a utility serial queue. The RDP thread only copies desktop pixels and replaces the mailbox. Neither frame-store nor mailbox locks span encoding or file I/O. When the input is not ready or the buffer pool reaches its threshold, the worker retains the latest frame and retries after 1/60 second. Retries stop when there is no pending frame. A static desktop encodes once; ending the writer session at stop time extends the final frame through the idle interval without duplicate samples.

Recording forces `SessionDisplay` updates on, including hidden tabs, minimized windows, and occluded windows. Stop removes that override and applies the current visibility state. Automatic RDP reconnect keeps the capture object, movie, timeline, and update override. Frames resume in the same movie after reconnect, with any new desktop size fitted into the original video size. Terminal disconnect finishes the movie. A later manual connection attempt starts with no old desktop snapshot.

Stop, explicit disconnect, terminal session end, and controller teardown all detach the movie from the frame sink before finishing it. Tab close and window close use the same controller disconnect path. `SessionTabs` retains captures from closed tabs until they finish, so quitting also waits for movies whose tabs have already disappeared. `AppDelegate.applicationShouldTerminate(_:)` disconnects sessions, returns `.terminateLater`, waits for all captures, and calls `reply(toApplicationShouldTerminate:)`. A pending frame has five seconds to drain. Movie finalization has an eight-second cancellation deadline. The app has a ten-second overall deadline and logs any unfinished destination and partial-file location before replying. Force Quit, process crashes, and power loss cannot run this teardown.

`ScreenshotDestination` reads `com.apple.screencapture` `location`, expands a tilde, and otherwise uses `~/Desktop`. An explicitly configured location that cannot be written produces a typed error rather than silently saving somewhere else. Names use local time, for example `Remora - Office - 2026-10-18 at 03.40.12.png` or `.mov`. Unsafe filename characters are replaced with hyphens. An exclusive file creation reserves the name; collisions add ` (2)`, ` (3)`, and so on. Movie encoding uses a unique hidden `.Remora-<UUID>.partial.mov` in that folder while the destination stays reserved. Successful finish atomically replaces that empty reservation. Failed writes delete the reservation and partial movie. A cleanup error reports the remaining path.

### Verification and remaining work

`swift test --package-path Packages/RemoraKit` runs the existing tests and two capture tests. The screenshot test destroys the padded borrowed storage after a callback with only a one-pixel dirty rectangle, then checks all decoded PNG pixels and dimensions. The movie test records synthetic desktops, changes aspect ratio, submits a burst faster than 60 fps, waits through an idle interval, finishes, and reads the resulting movie. It checks playability, HEVC, fixed dimensions, no audio, duration, sample spacing, decoded black letterboxing, and resized desktop color. Synthetic movie files are temporary and removed by the test.

The UI agent still needs to add menu actions, keyboard routing, a per-tab recording indicator, elapsed time, stop flow, and failure presentation. It should observe `session(for: id)?.capture`, including hidden tabs, rather than mirroring recording state into another store. Automatic lifecycle failures are also written to the session log. On-screen verification, real reconnect, encoder saturation, disk-full failure, and quit with a live remote session have not been exercised by these automated tests.

The on-screen verifier should use only a development instance it launches itself. It must leave the user's installed `/Applications/Remora.app` and other instances alone. Do not use Penguin, type passwords, modify saved connections or Keychain entries, or back up or restore the user's live `connections.json`. Use only the saved Windows connection `desktop-b8l68ps.tail5b813.ts.net` and only look at its desktop. Keep remote captures under `/Users/sdk/Projects/Remora/.snap/`; remove any test captures saved into the configured screenshot location.

- Verify save and clipboard screenshots after the desktop becomes idle. Compare native dimensions and the whole image, excluding the Mac toolbar, tab strip, and overlays.
- Verify a second save in the same second does not overwrite the first.
- Start recording, switch to home or another tab, and confirm the movie continues receiving desktop changes. Stop while hidden and confirm visibility-based suppression resumes.
- Resize a Fit to Window session during recording. Check fixed movie dimensions, preserved aspect ratio, and black bars.
- Check that idle time remains in the movie duration and playback seeks correctly.
- Exercise automatic reconnect while recording, then verify one playable file with the reconnect interval and resumed desktop frames.
- Separately test stop, tab close, Disconnect, terminal session end, window close through the Disconnect sheet, and normal app quit. Open every resulting movie after finalization.
- Check the observable finishing and failed states through the completed UI, including a destination that cannot be written. Confirm the app reports failures and no unexplained partial file remains.
