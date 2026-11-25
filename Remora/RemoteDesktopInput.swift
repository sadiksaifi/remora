import AppKit
import RemoraCore

/// AppKit event adaptation. The session owns the remote pressed state and queue.
@MainActor
final class RemoteDesktopInput: NSObject {
    weak var view: RemoteDesktopView?
    var input: (any RemoteSession)? {
        didSet {
            oldValue?.releaseHumanInput()
            keyboardRouting = KeyboardRouting()
            reset()
            focusIn()
        }
    }
    var allowsHumanInput = true {
        didSet {
            guard allowsHumanInput != oldValue else { return }
            focusOut()
            if allowsHumanInput { focusIn() }
        }
    }
    var onHumanInput: ((SessionControl.HumanInput) -> Void)?
    var onBlockedInput: (() -> Void)?
    private var connected = false
    private lazy var shortcutCapture = SystemShortcutCapture(
        isFocused: { [weak self] in self.map { $0.canCapture && !$0.menuIsOpen } ?? false },
        receive: { [weak self] event in self?.receiveKeyboardEvent(event) ?? false },
        releaseKeys: { [weak self] in
            guard let self else { return }
            keyboardRouting = KeyboardRouting()
            releaseKeys()
        }
    )
    private var hasFocus: Bool {
        connected && input != nil && NSApp.isActive && view?.window?.isKeyWindow == true && view?.window?.firstResponder === view
    }
    private var canCapture: Bool { hasFocus && allowsHumanInput }
    /// True while a menu of this app is open: one in the menu bar, a tab's, the toolbar's or the menu bar icon's.
    /// The menu takes every key until it closes. The desktop keeps the focus, so capture stays reported.
    private var menuIsOpen = false
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
        menuIsOpen = false
        guard let window = view?.window else { return }
        window.acceptsMouseMovedEvents = true
        // AppKit can consume Command key-ups before responder dispatch. Observe them
        // before dispatch so every forwarded shortcut gets its matching release.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let view = self.view,
                    event.window == nil || event.window === view.window
                else { return false }
                return self.receiveKeyboardEvent(event)
            }
            return handled ? nil : event
        }
        center.addObserver(self, selector: #selector(settingsChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusLost(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(focusGained(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(focusGained(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(menuOpened(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuClosed(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    @objc private func settingsChanged(_ notification: Notification) {
        if canCapture { shortcutCapture.start() } else { shortcutCapture.stop() }
    }

    @objc private func focusGained(_ notification: Notification) { focusIn() }
    @objc private func focusLost(_ notification: Notification) { focusOut() }

    /// The menu gets the keys from here on, so the remote computer would never see a held key released.
    @objc private func menuOpened(_ notification: Notification) {
        menuIsOpen = true
        guard hasFocus else { return }
        shortcutCapture.stop()
        keyboardRouting = KeyboardRouting()
        releaseKeys()
    }

    @objc private func menuClosed(_ notification: Notification) {
        menuIsOpen = false
        focusIn()
    }

    func setConnected(_ connected: Bool) {
        if !connected { focusOut() }
        self.connected = connected
        if connected { focusIn() }
    }

    func focusIn() {
        captureMayHaveChanged()
        guard canCapture else { return }
        becameFirstResponder()
    }

    func becameFirstResponder() {
        captureMayHaveChanged()
        guard allowsHumanInput, connected, input != nil, view?.window?.isKeyWindow == true, NSApp.isActive else { return }
        shortcutCapture.start()
        // AppKit can call becomeFirstResponder before assigning window.firstResponder.
        Task { @MainActor [weak self] in
            guard let self, canCapture else { return }
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
            guard canCapture != reportedCapture else { return }
            reportedCapture = canCapture
            onCaptureChange?(reportedCapture)
        }
    }

    private func releaseKeys() {
        input?.releaseHumanInput()
        reset()
    }

    private func reset() {
        keyboard = KeyboardState()
        scroll.reset()
        buttons = []
        lastPosition = nil
    }

    func key(_ event: NSEvent, down: Bool) {
        _ = receiveKeyboardEvent(event)
    }

    private func resetKeyboard() {
        // A key can still be down from a press that went elsewhere, such as the Escape that closed a menu.
        // The session's key state misses every event the capture discards, so it can show a released key as down.
        let held = (0..<128 as Range<UInt16>).filter { CGEventSource.keyState(.hidSystemState, key: $0) }
        keyboard.reset(
            capsLockOn: NSEvent.modifierFlags.contains(.capsLock),
            rawFlags: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue), heldKeys: Set(held))
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
        guard hasFocus, !menuIsOpen, let input else { return false }
        switch keyboardRouting.route(
            keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue,
            event: event.type == .flagsChanged
                ? .flagsChanged
                : event.type == .keyDown ? .keyDown : .keyUp)
        {
        case .local: return false
        case .deferModifiers: return true
        case .beginLocalChord:
            releaseKeys()
            return false
        case .releaseCapture:
            view?.window?.makeFirstResponder(nil)
            return true
        case .remote:
            guard allowsHumanInput else {
                if event.type == .keyDown { onBlockedInput?() }
                return !event.modifierFlags.contains(.command)
            }
            if event.type == .keyDown { onHumanInput?(.key) }
            let keys =
                event.type == .flagsChanged
                ? keyboard.flagsChanged(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue)
                : keyboard.key(
                    keyCode: event.keyCode, isDown: event.type == .keyDown,
                    rawFlags: event.modifierFlags.rawValue)
            for key in keys {
                input.sendKey(
                    KeyInput(
                        keyCode: key.keyCode, isDown: key.isDown,
                        characters: key.keyCode == event.keyCode && event.type == .keyDown ? event.characters : nil))
            }
            return true
        }
    }

    /// Presses and releases Control, Option, and Forward Delete, which reach the remote computer as Ctrl-Alt-Del.
    func sendCtrlAltDelete() {
        guard allowsHumanInput, connected, let input else { return }
        onHumanInput?(.key)
        releaseKeys()
        let keys: [UInt16] = [0x3B, 0x3A, 0x75]
        for key in keys { input.sendKey(KeyInput(keyCode: key, isDown: true)) }
        for key in keys.reversed() { input.sendKey(KeyInput(keyCode: key, isDown: false)) }
    }

    func pointer(_ event: NSEvent, down: Bool? = nil) {
        if !allowsHumanInput, connected, down == true { onBlockedInput?() }
        guard allowsHumanInput, connected, let input, let view else { return }
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
                onHumanInput?(.click)
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
        guard allowsHumanInput, connected, let input, let view,
            let point = view.remotePoint(for: view.convert(event.locationInWindow, from: nil))
        else { return }
        onHumanInput?(.scroll)
        let wheel = scroll.accumulate(
            x: event.scrollingDeltaX, y: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas)
        guard wheel.vertical != 0 || wheel.horizontal != 0 else { return }
        // Pointer motion is not tracked while the window is inactive, so the
        // last pointer position can be stale. The wheel turns under the cursor.
        let position = RemotePoint(x: UInt16(clamping: Int(point.x)), y: UInt16(clamping: Int(point.y)))
        lastPosition = position
        input.sendWheel(wheel, at: position)
    }
}
