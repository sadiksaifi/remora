import AppKit
import RemoraCore

/// AppKit event adaptation. The session owns the remote pressed state and queue.
@MainActor
final class RemoteDesktopInput: NSObject {
    weak var view: RemoteDesktopView?
    var input: (any RemoteSession)? {
        didSet {
            oldValue?.releaseAll()
            keyboardRouting = KeyboardRouting()
            reset()
            focusIn()
        }
    }
    private var connected = false
    private lazy var shortcutCapture = SystemShortcutCapture(
        isFocused: { [weak self] in self?.hasFocus == true },
        receive: { [weak self] event in self?.receiveKeyboardEvent(event) ?? false },
        releaseKeys: { [weak self] in
            guard let self else { return }
            keyboardRouting = KeyboardRouting()
            releaseKeys()
        }
    )
    private var hasFocus: Bool {
        connected && input != nil && NSApp.isActive && view?.window?.isKeyWindow == true &&
            view?.window?.firstResponder === view
    }
    private var keyboard = KeyboardState()
    private var keyboardRouting = KeyboardRouting()
    private var scroll = ScrollAccumulator()
    private var buttons: PointerButtons = []
    private var lastPosition: RemotePoint?
    private var keyUpMonitor: Any?
    /// Called when the desktop gains or loses the keyboard of the active key window.
    var onCaptureChange: ((Bool) -> Void)?
    private var reportedCapture = false

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
                guard let self, let view = self.view,
                      event.window == nil || event.window === view.window else { return false }
                return self.receiveKeyboardEvent(event)
            }
            return handled ? nil : event
        }
        center.addObserver(self, selector: #selector(settingsChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(focusGained(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusGained(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func settingsChanged(_ notification: Notification) {
        if hasFocus { shortcutCapture.start() } else { shortcutCapture.stop() }
    }

    @objc private func focusGained(_ notification: Notification) { focusIn() }
    @objc private func focusLost(_ notification: Notification) { focusOut() }

    func setConnected(_ connected: Bool) {
        if !connected { focusOut() }
        self.connected = connected
        if connected { focusIn() }
    }

    func focusIn() {
        captureMayHaveChanged()
        guard hasFocus else { return }
        becameFirstResponder()
    }

    func becameFirstResponder() {
        captureMayHaveChanged()
        guard connected, input != nil, view?.window?.isKeyWindow == true, NSApp.isActive else { return }
        shortcutCapture.start()
        // AppKit can call becomeFirstResponder before assigning window.firstResponder.
        Task { @MainActor [weak self] in
            guard let self, hasFocus else { return }
            shortcutCapture.start()
            view?.onFocus?()
        }
        resetKeyboard()
        input?.synchronize(locks: NSEvent.modifierFlags.contains(.capsLock) ? [.capsLock] : [])
    }

    func focusOut() {
        captureMayHaveChanged()
        shortcutCapture.stop()
        keyboardRouting = KeyboardRouting()
        releaseKeys()
    }

    /// AppKit finishes a focus change after the call that announces it, so the state is read on the next turn.
    /// The task keeps this object alive, so a desktop leaving its window still reports the release.
    private func captureMayHaveChanged() {
        Task { @MainActor in
            guard hasFocus != reportedCapture else { return }
            reportedCapture = hasFocus
            onCaptureChange?(reportedCapture)
        }
    }

    private func releaseKeys() {
        input?.releaseAll()
        reset()
    }

    private func reset() {
        resetKeyboard()
        scroll.reset()
        buttons = []
        lastPosition = nil
    }

    func key(_ event: NSEvent, down: Bool) {
        _ = receiveKeyboardEvent(event)
    }

    private func resetKeyboard() {
        keyboard.reset(capsLockOn: NSEvent.modifierFlags.contains(.capsLock),
                       rawFlags: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
    }

    func flagsChanged(_ event: NSEvent) {
        _ = receiveKeyboardEvent(event)
    }

    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        return receiveKeyboardEvent(event)
    }

    /// The tap consumes remote events, so AppKit only sees bypass events and local chords.
    /// Both routes use the same eligibility, shortcut policy, and pressed-key state.
    private func receiveKeyboardEvent(_ event: NSEvent) -> Bool {
        guard hasFocus, let input else { return false }
        switch keyboardRouting.route(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue,
                                     event: event.type == .flagsChanged ? .flagsChanged
                                        : event.type == .keyDown ? .keyDown : .keyUp) {
        case .local: return false
        case .deferModifiers: return true
        case .beginLocalChord:
            releaseKeys()
            return false
        case .releaseCapture:
            view?.window?.makeFirstResponder(nil)
            return true
        case .remote:
            let keys = event.type == .flagsChanged
                ? keyboard.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue)
                : keyboard.key(keyCode: event.keyCode, isDown: event.type == .keyDown,
                               rawFlags: event.modifierFlags.rawValue)
            for key in keys { input.sendKey(key) }
            return true
        }
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
