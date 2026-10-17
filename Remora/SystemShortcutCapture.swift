import AppKit
import ApplicationServices

/// An active filter on the main run loop. Its owner must stop it before releasing input.
@MainActor
final class SystemShortcutCapture {
    static var isTrusted: Bool { AXIsProcessTrusted() }
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
        guard Self.isTrusted else { stop(); return }
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
        guard isFocused() else { stop(); return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let key = NSEvent(cgEvent: event) else { return false }
        let flags = key.modifierFlags.intersection([.command, .control, .option, .shift])
        if type == .keyDown {
            // Ctrl-Option-Cmd-Escape releases capture locally. Click the desktop to capture again.
            if key.keyCode == 0x35 && flags == [.control, .option, .command] {
                releaseCapture()
                return true
            }
            if (key.keyCode == 0x0C && flags == .command) ||
               (key.keyCode == 0x03 && flags == [.control, .command]) {
                releaseKeys()
                localChord = true
            }
        }
        if localChord {
            if flags.isEmpty { localChord = false }
            return false
        }
        receive(key)
        return true
    }
}
