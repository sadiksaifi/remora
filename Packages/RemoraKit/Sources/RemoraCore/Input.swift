import Foundation

public struct KeyInput: Sendable, Equatable {
    public let keyCode: UInt16
    public let isDown: Bool
    public let characters: String?

    public init(keyCode: UInt16, isDown: Bool, characters: String? = nil) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.characters = characters
    }
}

public struct RemotePoint: Sendable, Equatable {
    public let x: UInt16
    public let y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }
}

public struct PointerButtons: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = Self(rawValue: 1)
    public static let right = Self(rawValue: 2)
    public static let middle = Self(rawValue: 4)
    public static let back = Self(rawValue: 8)
    public static let forward = Self(rawValue: 16)
}

public struct LockKeys: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let capsLock = Self(rawValue: 1)
    public static let numLock = Self(rawValue: 2)
    public static let scrollLock = Self(rawValue: 4)
}

/// Signed wheel rotation in 1/120-notch units. Positive is up/right.
public struct WheelInput: Sendable, Equatable {
    public let vertical: Int32
    public let horizontal: Int32

    public init(vertical: Int32, horizontal: Int32) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

public enum RemoteCursor: Sendable, Equatable {
    /// Straight-alpha BGRA bytes, tightly packed. Dimensions and hotspot are remote pixels.
    case image(pixels: Data, width: Int, height: Int, hotspot: RemotePoint)
    case hidden
    case systemDefault
}

/// NSEvent deltas already include the user's natural scrolling preference.
public struct ScrollAccumulator: Sendable {
    private var x = 0.0
    private var y = 0.0

    public init() {}

    public mutating func accumulate(x deltaX: Double, y deltaY: Double, precise: Bool) -> WheelInput {
        // Forty trackpad points or one mouse-wheel line make one 120-unit notch.
        let multiplier = precise ? 3.0 : 120.0
        return WheelInput(
            vertical: Self.take(deltaY * multiplier, remainder: &y),
            // Cocoa's positive X points left; RDP's and VNC's positive X points right.
            horizontal: Self.take(-deltaX * multiplier, remainder: &x)
        )
    }

    public mutating func reset() {
        x = 0
        y = 0
    }

    private static func take(_ delta: Double, remainder: inout Double) -> Int32 {
        guard delta.isFinite else { return 0 }
        let total = remainder + delta
        let whole = min(max(total.rounded(.towardZero), Double(Int32.min)), Double(Int32.max))
        remainder = total - whole
        return Int32(whole)
    }
}

/// Tracks physical keys without depending on AppKit. Raw flags retain NX_DEVICE* bits.
public struct KeyboardState: Sendable {
    private var pressed: Set<UInt16> = []
    private var capsLockOn = false
    private var staleModifiers: UInt = 0

    public init() {}

    public mutating func key(keyCode: UInt16, isDown: Bool, rawFlags: UInt? = nil) -> [KeyInput] {
        guard Self.modifierMask(keyCode) == nil, keyCode != 0x39, keyCode != 0x3F else { return [] }
        let modifiers = isDown ? rawFlags.map { flagsChanged(keyCode: 0, rawFlags: $0) } ?? [] : []
        if isDown {
            pressed.insert(keyCode)
        } else if pressed.remove(keyCode) == nil {
            return []
        }
        // Forward ordinary repeat downs. The bridge marks repeats for Windows.
        return modifiers + [KeyInput(keyCode: keyCode, isDown: isDown)]
    }

    public mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt) -> [KeyInput] {
        if keyCode == 0x39 {
            let on = rawFlags & 0x10000 != 0  // NX_ALPHASHIFTMASK
            guard on != capsLockOn else { return [] }
            capsLockOn = on
            return [KeyInput(keyCode: keyCode, isDown: true), KeyInput(keyCode: keyCode, isDown: false)]
        }
        let flags = modifierFlags(rawFlags, keyCode: keyCode)
        staleModifiers &= flags
        var changes: [KeyInput] = []
        for key: UInt16 in [0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E] {
            let down = flags & ~staleModifiers & Self.modifierMask(key)! != 0
            guard down != pressed.contains(key) else { continue }
            if down { pressed.insert(key) } else { pressed.remove(key) }
            changes.append(KeyInput(keyCode: key, isDown: down))
        }
        return changes
    }

    public mutating func releaseAll() -> [KeyInput] {
        let releases = pressed.sorted().map { KeyInput(keyCode: $0, isDown: false) }
        pressed.removeAll()
        return releases
    }

    public mutating func reset(capsLockOn: Bool, rawFlags: UInt = 0) {
        pressed.removeAll()
        self.capsLockOn = capsLockOn
        staleModifiers = 0
        staleModifiers = modifierFlags(rawFlags, keyCode: 0)
    }

    /// Aggregate-only accessibility events omit the side. Retain known held sides,
    /// including suppressed keys after focus loss; otherwise choose the event's side or left.
    private func modifierFlags(_ rawFlags: UInt, keyCode: UInt16) -> UInt {
        var flags: UInt = 0
        for (aggregate, left, right): (UInt, UInt16, UInt16) in [
            (0x20000, 0x38, 0x3C), (0x40000, 0x3B, 0x3E),
            (0x80000, 0x3A, 0x3D), (0x100000, 0x37, 0x36),
        ] {
            let mask = Self.modifierMask(left)! | Self.modifierMask(right)!
            let device = rawFlags & mask
            if device != 0 {
                flags |= device
            } else if rawFlags & aggregate != 0 {
                let held = [left, right].reduce(staleModifiers & mask) {
                    $0 | (pressed.contains($1) ? Self.modifierMask($1)! : 0)
                }
                flags |= held != 0 ? held : Self.modifierMask(keyCode == right ? right : left)!
            }
        }
        return flags
    }

    private static func modifierMask(_ key: UInt16) -> UInt? {
        switch key {
        case 0x38: 0x0002  // NX_DEVICELSHIFTKEYMASK
        case 0x3C: 0x0004  // NX_DEVICERSHIFTKEYMASK
        case 0x3B: 0x0001  // NX_DEVICELCTLKEYMASK
        case 0x3E: 0x2000  // NX_DEVICERCTLKEYMASK
        case 0x3A: 0x0020  // NX_DEVICELALTKEYMASK
        case 0x3D: 0x0040  // NX_DEVICERALTKEYMASK
        case 0x37: 0x0008  // NX_DEVICELCMDKEYMASK
        case 0x36: 0x0010  // NX_DEVICERCMDKEYMASK
        default: nil
        }
    }
}

/// The same policy runs at the system tap and for events delivered directly to the app.
/// A local event can pass through both routes; keep the entire chord local until release.
public struct KeyboardRouting: Sendable {
    public enum Event: Sendable {
        case keyDown, keyUp, flagsChanged
    }

    public enum Disposition: Sendable, Equatable {
        case remote
        case local
        case beginLocalChord
        case releaseCapture
        case deferModifiers
    }

    private var localChord = false

    public init() {}

    public mutating func route(keyCode: UInt16, rawFlags: UInt, event: Event) -> Disposition {
        let modifiers = rawFlags & 0x1E0000  // Shift, Control, Option, Command.
        if event == .keyDown {
            if keyCode == 0x35, modifiers == 0x1C0000 { return .releaseCapture }
            let local: Bool
            switch modifiers {
            case 0x100000: local = keyCode == 0x0C  // Cmd-Q.
            case 0x140000: local = keyCode == 0x03  // Ctrl-Cmd-F.
            case 0x1C0000: local = Self.localChordKeys.contains(keyCode)
            case 0x1E0000: local = keyCode == 0x01  // Copy Screenshot.
            default: local = false
            }
            if local {
                let disposition: Disposition = localChord ? .local : .beginLocalChord
                localChord = true
                return disposition
            }
        }
        if localChord {
            if modifiers == 0 { localChord = false }
            return .local
        }
        // Modifier-only chords can trigger host actions. Do not send the complete
        // reserved prefix until a non-local key needs it.
        if event == .flagsChanged, modifiers & 0x1C0000 == 0x1C0000 { return .deferModifiers }
        return .remote
    }

    private static let localChordKeys: Set<UInt16> = [
        0x21, 0x1E, 0x04, 0x0D, 0x01, 0x0F, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x7B, 0x7C,
    ]
}
