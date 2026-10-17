import AppKit
import RemoraCore

/// AppKit event adaptation. The session owns the remote pressed state and queue.
@MainActor
final class RemoteDesktopInput: NSObject {
    weak var view: RemoteDesktopView?
    var input: (any RemoteSession)? {
        didSet {
            oldValue?.releaseAll()
            reset()
            focusIn()
        }
    }
    private var connected = false
    private lazy var shortcutCapture = SystemShortcutCapture(
        isFocused: { [weak self] in self?.hasFocus == true },
        receive: { [weak self] event in
            guard let self else { return }
            if event.type == .flagsChanged { flagsChanged(event, captured: true) }
            else { key(event, down: event.type == .keyDown, captured: true) }
        },
        releaseKeys: { [weak self] in self?.releaseKeys() },
        releaseCapture: { [weak self] in self?.view?.window?.makeFirstResponder(nil) }
    )
    private var hasFocus: Bool {
        connected && input != nil && NSApp.isActive && view?.window?.isKeyWindow == true &&
            view?.window?.firstResponder === view
    }
    private var keyboard = KeyboardState()
    private var scroll = ScrollAccumulator()
    private var buttons: PointerButtons = []
    private var lastPosition: RemotePoint?
    private var keyUpMonitor: Any?

    init(view: RemoteDesktopView) { self.view = view }

    isolated deinit {
        shortcutCapture.stop()
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
    }

    func movedToWindow() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        keyUpMonitor = nil
        guard let window = view?.window else { return }
        window.acceptsMouseMovedEvents = true
        // AppKit can consume Command key-ups before responder dispatch. Observe them
        // before dispatch so every forwarded shortcut gets its matching release.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.connected, !self.shortcutCapture.isActive, self.input != nil, let view = self.view,
                      view.window?.isKeyWindow == true, view.window?.firstResponder === view,
                      event.window === view.window else { return false }
                self.key(event, down: false)
                return true
            }
            return handled ? nil : event
        }
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(focusGained(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusGained(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func focusGained(_ notification: Notification) { focusIn() }
    @objc private func focusLost(_ notification: Notification) { focusOut() }

    func setConnected(_ connected: Bool) {
        if !connected { focusOut() }
        self.connected = connected
        if connected { focusIn() }
    }

    func focusIn() {
        guard hasFocus else { return }
        becameFirstResponder()
    }

    func becameFirstResponder() {
        guard connected, input != nil, view?.window?.isKeyWindow == true, NSApp.isActive else { return }
        shortcutCapture.start()
        // AppKit can call becomeFirstResponder before assigning window.firstResponder.
        Task { @MainActor [weak self] in self?.shortcutCapture.start() }
        view?.onFocus?()
        let caps = NSEvent.modifierFlags.contains(.capsLock)
        keyboard.reset(capsLockOn: caps)
        input?.synchronize(locks: caps ? [.capsLock] : [])
    }

    func focusOut() {
        shortcutCapture.stop()
        releaseKeys()
    }

    private func releaseKeys() {
        input?.releaseAll()
        reset()
    }

    private func reset() {
        keyboard.reset(capsLockOn: NSEvent.modifierFlags.contains(.capsLock))
        scroll.reset()
        buttons = []
        lastPosition = nil
    }

    func key(_ event: NSEvent, down: Bool, captured: Bool = false) {
        guard connected, captured || !shortcutCapture.isActive, let input else { return }
        for key in keyboard.key(keyCode: event.keyCode, isDown: down) {
            input.sendKey(key)
        }
    }

    func flagsChanged(_ event: NSEvent, captured: Bool = false) {
        guard connected, captured || !shortcutCapture.isActive, let input else { return }
        for key in keyboard.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue) {
            input.sendKey(key)
        }
    }

    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard connected, !shortcutCapture.isActive, input != nil, let view, view.window?.firstResponder === view,
              event.modifierFlags.contains(.command) else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        // Keep Cmd-Q and Cmd-Ctrl-F local as explicit exit/full-screen shortcuts, and
        // Ctrl-Option-Cmd-Escape for the Release Keyboard Capture menu item.
        if (event.keyCode == 0x0C && flags == .command) ||
           (event.keyCode == 0x03 && flags == [.command, .control]) ||
           (event.keyCode == 0x35 && flags == [.command, .control, .option]) { return false }
        key(event, down: true)
        return true
    }

    /// Presses and releases Control, Option, and Forward Delete, which RDP maps to Ctrl-Alt-Del.
    func sendCtrlAltDelete() {
        guard connected, let input else { return }
        releaseKeys()
        let keys: [UInt16] = [0x3B, 0x3A, 0x75]
        for key in keys { input.sendKey(KeyInput(keyCode: key, isDown: true)) }
        for key in keys.reversed() { input.sendKey(KeyInput(keyCode: key, isDown: false)) }
    }

    func pointer(_ event: NSEvent, down: Bool? = nil) {
        guard connected, let input, let view else { return }
        if down == true { view.window?.makeFirstResponder(view) }
        let point = view.remotePoint(for: view.convert(event.locationInWindow, from: nil))
        let button: PointerButtons
        switch event.buttonNumber {
        case 0: button = .left
        case 1: button = .right
        case 2: button = .middle
        case 3: button = .back
        case 4: button = .forward
        default: button = []
        }
        if let down {
            guard !button.isEmpty else { return }
            if down {
                guard point != nil else { return }
                buttons.insert(button)
            } else {
                guard buttons.contains(button) else { return }
                buttons.remove(button)
            }
        }
        if let point {
            lastPosition = RemotePoint(x: UInt16(clamping: Int(point.x)), y: UInt16(clamping: Int(point.y)))
        } else if down != false {
            return
        }
        // A drag may end over a letterbox bar. Release at its last remote position;
        // bars never produce remote coordinates or begin a remote button press.
        guard let position = lastPosition else { return }
        input.sendPointer(position: position, buttons: buttons)
    }

    func scrollWheel(_ event: NSEvent) {
        guard connected, let input, let view,
              view.remotePoint(for: view.convert(event.locationInWindow, from: nil)) != nil else { return }
        let wheel = scroll.accumulate(x: event.scrollingDeltaX, y: event.scrollingDeltaY,
                                      precise: event.hasPreciseScrollingDeltas)
        if wheel.vertical != 0 || wheel.horizontal != 0 { input.sendWheel(wheel) }
    }
}
