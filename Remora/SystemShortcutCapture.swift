import AppKit
@preconcurrency import ApplicationServices

/// An active filter on the main run loop. Its owner must stop it before releasing input.
@MainActor
final class SystemShortcutCapture {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The Settings toggle. Capture is on unless the user turned it off.
    nonisolated static let enabledKey = "CaptureSystemShortcuts"
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

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let isFocused: () -> Bool
    private let receive: (NSEvent) -> Bool
    private let releaseKeys: () -> Void

    init(isFocused: @escaping () -> Bool, receive: @escaping (NSEvent) -> Bool,
         releaseKeys: @escaping () -> Void) {
        self.isFocused = isFocused
        self.receive = receive
        self.releaseKeys = releaseKeys
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
    }

    private func filter(type: CGEventType, event: CGEvent) -> Bool {
        guard isFocused(), Self.isEnabled else { stop(); return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseKeys()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let key = NSEvent(cgEvent: event) else { return false }
        return receive(key)
    }
}
