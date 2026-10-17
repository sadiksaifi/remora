import AppKit
@preconcurrency import ApplicationServices

/// An active filter on the main run loop. Its owner must stop it before releasing input.
@MainActor
final class SystemShortcutCapture {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The Settings toggle. Capture is on unless the user turned it off.
    static let enabledKey = "CaptureSystemShortcuts"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Opens the Privacy & Security pane that grants Accessibility trust. macOS 27 names it
    /// Device Control and Data Access. An untrusted Remora first asks to be added to that list,
    /// which can also show the system prompt.
    static func openAccessibilitySettings() {
        if !isTrusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
    }

    /// The release chord: Control-Option-Command-Escape.
    static func isReleaseChord(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 0x35 && flags.intersection(shortcutModifiers) == [.control, .option, .command]
    }

    /// Shortcuts that act on this Mac even while the desktop has the keyboard: Command-Q,
    /// Control-Command-F, and the Control-Option-Command family for tabs, Connections, and the release chord.
    static func staysLocal(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch flags.intersection(shortcutModifiers) {
        case .command: keyCode == 0x0C // Q
        case [.control, .command]: keyCode == 0x03 // F
        case [.control, .option, .command]: localChordKeys.contains(keyCode)
        default: false
        }
    }

    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    /// Escape, [, ], H, W, and 1 through 9.
    private static let localChordKeys: Set<UInt16> = [
        0x35, 0x21, 0x1E, 0x04, 0x0D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19,
    ]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localChord = false
    private let isFocused: () -> Bool
    private let receive: (NSEvent) -> Void
    private let releaseKeys: () -> Void
    private let releaseCapture: () -> Void

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    init(isFocused: @escaping () -> Bool, receive: @escaping (NSEvent) -> Void,
         releaseKeys: @escaping () -> Void, releaseCapture: @escaping () -> Void) {
        self.isFocused = isFocused
        self.receive = receive
        self.releaseKeys = releaseKeys
        self.releaseCapture = releaseCapture
    }

    isolated deinit { stop() }

    func start() {
        guard isFocused() else { return }
        guard Self.isEnabled, Self.isTrusted else { stop(); return }
        if let tap {
            if CFMachPortIsValid(tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                return
            }
            stop()
        }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        // CGEvent.h permits active keyboard filters for trusted accessibility clients.
        // Listen-event preflight only checks passive Input Monitoring access.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, user in
                let discard = MainActor.assumeIsolated {
                    let owner = Unmanaged<SystemShortcutCapture>.fromOpaque(user!).takeUnretainedValue()
                    return owner.filter(type: type, event: event)
                }
                return discard ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return } // Secure Event Input or a permission change can prevent creation.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        localChord = false
    }

    private func filter(type: CGEventType, event: CGEvent) -> Bool {
        guard isFocused(), Self.isEnabled else { stop(); return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let key = NSEvent(cgEvent: event) else { return false }
        if type == .keyDown {
            // Ctrl-Option-Cmd-Escape releases capture locally. Click the desktop to capture again.
            if Self.isReleaseChord(keyCode: key.keyCode, flags: key.modifierFlags) {
                releaseCapture()
                return true
            }
            // Other local shortcuts reach the menus while the desktop keeps the keyboard.
            if Self.staysLocal(keyCode: key.keyCode, flags: key.modifierFlags) {
                releaseKeys()
                localChord = true
            }
        }
        if localChord {
            if key.modifierFlags.intersection(Self.shortcutModifiers).isEmpty { localChord = false }
            return false
        }
        receive(key)
        return true
    }
}
