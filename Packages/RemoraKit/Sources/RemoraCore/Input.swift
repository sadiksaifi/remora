import Foundation

public struct KeyInput: Sendable, Equatable {
    public let keyCode: UInt16
    public let isDown: Bool

    public init(keyCode: UInt16, isDown: Bool) {
        self.keyCode = keyCode
        self.isDown = isDown
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
            // Cocoa's positive X points left; RDP/SDL's positive X points right.
            horizontal: Self.take(-deltaX * multiplier, remainder: &x)
        )
    }

    public mutating func reset() { x = 0; y = 0 }

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

    public init() {}

    public mutating func key(keyCode: UInt16, isDown: Bool) -> [KeyInput] {
        guard Self.modifierMask(keyCode) == nil, keyCode != 0x39, keyCode != 0x3F else { return [] }
        if isDown {
            pressed.insert(keyCode)
        } else if pressed.remove(keyCode) == nil {
            return []
        }
        // Forward ordinary repeat downs. The bridge marks repeats for Windows.
        return [KeyInput(keyCode: keyCode, isDown: isDown)]
    }

    public mutating func flagsChanged(keyCode: UInt16, rawFlags: UInt) -> [KeyInput] {
        if keyCode == 0x39 {
            let on = rawFlags & 0x10000 != 0 // NX_ALPHASHIFTMASK
            guard on != capsLockOn else { return [] }
            capsLockOn = on
            return [KeyInput(keyCode: keyCode, isDown: true), KeyInput(keyCode: keyCode, isDown: false)]
        }
        guard let mask = Self.modifierMask(keyCode) else { return [] }
        let down = rawFlags & mask != 0
        guard down != pressed.contains(keyCode) else { return [] }
        if down { pressed.insert(keyCode) } else { pressed.remove(keyCode) }
        return [KeyInput(keyCode: keyCode, isDown: down)]
    }

    public mutating func releaseAll() -> [KeyInput] {
        let releases = pressed.sorted().map { KeyInput(keyCode: $0, isDown: false) }
        pressed.removeAll()
        return releases
    }

    public mutating func reset(capsLockOn: Bool) {
        pressed.removeAll()
        self.capsLockOn = capsLockOn
    }

    private static func modifierMask(_ key: UInt16) -> UInt? {
        switch key {
        case 0x38: 0x0002 // NX_DEVICELSHIFTKEYMASK
        case 0x3C: 0x0004 // NX_DEVICERSHIFTKEYMASK
        case 0x3B: 0x0001 // NX_DEVICELCTLKEYMASK
        case 0x3E: 0x2000 // NX_DEVICERCTLKEYMASK
        case 0x3A: 0x0020 // NX_DEVICELALTKEYMASK
        case 0x3D: 0x0040 // NX_DEVICERALTKEYMASK
        case 0x37: 0x0008 // NX_DEVICELCMDKEYMASK
        case 0x36: 0x0010 // NX_DEVICERCMDKEYMASK
        default: nil
        }
    }
}
