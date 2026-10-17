# Architecture

Remora is a native macOS remote desktop client. V1 speaks RDP through FreeRDP 3.x. VNC comes later behind the same session interface.

This is personal software. Prefer an existing library or a FreeRDP built-in over writing our own. Write code only where nothing suitable exists.

## Platform

- macOS 26.0 and later, arm64 only.
- Swift 6 language mode with complete strict concurrency.
- AppKit for windows, the connection list, and the session view. SwiftUI in `NSHostingController` for sheets and Settings.
- Apple's macOS 27 Human Interface Guidelines are the design baseline. Liquid Glass comes from standard AppKit controls.
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

## Session interface

One Swift protocol in RemoraCore. The app never sees FreeRDP types.

- Commands in: connect, disconnect, key, pointer, wheel, request resize, local clipboard text.
- Events out: state (connecting, awaiting credentials, awaiting trust, connected, reconnecting, disconnected with a typed reason), desktop size, cursor, remote clipboard text.
- Frames go to an injected frame sink, not through the event stream.
- A resize request is not a size change. Only the desktop size event resizes the renderer.

## Threading

- Each session owns one dedicated thread. It runs `freerdp_connect`, the event loop, and every FreeRDP call.
- Input, resize, clipboard, and disconnect commands go through a locked queue plus a wake event in the event loop's wait set.
- `freerdp_abort_connect_context` is the only cross-thread FreeRDP call.
- FreeRDP callbacks arrive on several threads (GFX and Display Control on the dynamic channel thread, clipboard on its own). The bridge copies data upward and never assumes a thread.
- Credential and trust callbacks block the session thread on a condition variable until the MainActor answers.
- Frame pixels are borrowed for the duration of the frame callback only. FreeRDP replaces the buffer on resize.

## Rendering

`CAMetalLayer` with one private BGRA texture. The renderer copies dirty rectangles into shared staging buffers, then blits the accumulated damage and draws one opaque quad in the same command buffer. Semaphores prevent CPU writes while the GPU reads a staging buffer. `NSView.displayLink` paces presentation, with at most one command buffer in flight. Pending damage coalesces instead of queueing frames; an idle desktop submits no GPU work. Pixels are tagged sRGB. Scaling uses aspect fit with black letterboxing, nearest sampling at 1:1, and linear sampling otherwise.

## Input

- The session view is first responder and handles `keyDown`, `keyUp`, `flagsChanged`, and `performKeyEquivalent`.
- Key events carry the macOS virtual key code. RDP maps it with WinPR's Apple keycode table to scancodes.
- Physical mapping: Command is Windows/Super, Control is Control, Option is Alt.
- The keyboard layout announced to the server follows the current Mac input source.
- All pressed keys and buttons are released when the window loses key status or the app deactivates.
- Scroll accumulates into 1/120-notch wheel units.
- System shortcuts (Cmd-Tab, Cmd-Space) are captured with a `CGEventTap` while a session window is key. This needs the Accessibility permission. Without it, those shortcuts stay local.

## Codecs

- Progressive RemoteFX, AVC420, and AVC444 are enabled explicitly. FreeRDP's library defaults leave them off.
- H.264 decodes through FFmpeg with VideoToolbox acceleration and FFmpeg software fallback.

## Storage

- Saved connections: a JSON file in Application Support.
- Passwords: Keychain via KeychainAccess, keyed by connection ID.
- Certificates: FreeRDP's own certificate store, with `ConfigPath` inside Application Support. Remora shows the trust dialog.

## License

GPL-3.0-or-later. Every dependency is compatible, and it keeps LibVNCClient available for the VNC phase. Distribution is outside the Mac App Store.
