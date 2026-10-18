#if DEBUG
import AppKit
import RemoraCore

/// Run Remora --shortcut-capture-demo to inspect the real input path without a server.
@MainActor
final class ShortcutCaptureDemo: NSWindowController, NSWindowDelegate {
    private let desktop: RemoteDesktopView
    private let session = LoggingSession()

    init(renderer: FrameRenderer) {
        desktop = RemoteDesktopView(renderer: renderer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Shortcut capture demo: Ctrl-Option-Cmd-Escape releases capture"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        desktop.input = session
        window.contentView = desktop
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(desktop)
        desktop.setSessionConnected(true)
        NSLog("ShortcutCaptureDemo Accessibility trusted=%@", SystemShortcutCapture.isTrusted.description)
        // Always remove capture and quit promptly; this Mac may have other live sessions.
        Task { @MainActor in
            let verify = CommandLine.arguments.contains("--verify-shortcut-capture")
            try? await Task.sleep(for: .seconds(verify ? 1 : 3))
            if verify, window.isKeyWindow, NSApp.isActive, window.firstResponder === desktop,
               SystemShortcutCapture.isTrusted {
                let commandDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x37, keyDown: true)!
                commandDown.type = .flagsChanged
                // KeyboardState reconciles the physical left/right NX_DEVICE bits.
                let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0008)
                commandDown.flags = commandFlags
                let tabDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: true)!
                tabDown.flags = commandFlags
                let tabUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: false)!
                tabUp.flags = commandFlags
                let commandUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x37, keyDown: false)!
                commandUp.type = .flagsChanged
                commandUp.flags = []
                for event in [commandDown, tabDown, tabUp, commandUp] { event.post(tap: .cghidEventTap) }
                try? await Task.sleep(for: .milliseconds(500))
                NSLog("ShortcutCaptureDemo after Cmd-Tab keyWindow=%@ active=%@",
                      window.isKeyWindow.description, NSApp.isActive.description)
            } else if verify {
                NSLog("ShortcutCaptureDemo verification skipped: focus or Accessibility unavailable")
            }
            desktop.setSessionConnected(false)
            NSLog("ShortcutCaptureDemo capture removed; exiting")
            NSApp.terminate(nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(renderer:)") }

    func windowWillClose(_ notification: Notification) {
        desktop.setSessionConnected(false)
    }
}

private final class LoggingSession: RemoteSession, Sendable {
    let events = AsyncStream<SessionEvent> { $0.finish() }
    var supportsDynamicResize: Bool { false }
    var maximumResizeArea: UInt64? { nil }
    func requestResize(_ size: DesktopSize, scale: Double) {}
    func setDisplayUpdatesEnabled(_ enabled: Bool) {}
    func connect() {}
    func disconnect() {}
    func sendKey(_ key: KeyInput) {
        NSLog("ShortcutCaptureDemo key=0x%02x down=%@", key.keyCode, key.isDown.description)
    }
    func sendPointer(position: RemotePoint, buttons: PointerButtons) {}
    func sendWheel(_ wheel: WheelInput) {}
    func synchronize(locks: LockKeys) {}
    func releaseAll() { NSLog("ShortcutCaptureDemo releaseAll") }
    func setLocalClipboard(text: String) {}
}
#endif
