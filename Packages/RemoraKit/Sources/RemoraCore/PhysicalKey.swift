import Foundation

/// Physical set-1 positions from FreeRDP's scancode.h. Extended keys carry bit 8.
public struct PhysicalKey: Sendable, Hashable {
    public let name: String
    public let scancode: UInt32
    public let isModifier: Bool
    public var isPause: Bool { name == "Pause" }

    public static var names: [String] { table.values.map(\.name).sorted() }

    public static func chord(_ text: String, modifiersOnly: Bool = false) throws -> [Self] {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false)
        var keys: [Self] = []
        for token in tokens {
            let lower = token.lowercased()
            guard let key = table[aliases[lower] ?? lower] else {
                throw ParseFailure("Unknown physical key '\(token)'. Use Delete for forward delete, Backspace for backward delete, or type for literal text.")
            }
            guard !keys.contains(key) else { throw ParseFailure("A chord cannot repeat \(key.name).") }
            keys.append(key)
        }
        guard !keys.isEmpty, modifiersOnly ? keys.allSatisfy(\.isModifier)
                : (keys.count == 1 || (keys.dropLast().allSatisfy(\.isModifier) && !keys.last!.isModifier)) else {
            throw ParseFailure("Use modifiers followed by one key. Use batch key-down actions to hold multiple keys.")
        }
        return keys
    }

    private struct ParseFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static let aliases: [String: String] = {
        var result: [String: String] = [:]
        for (canonical, aliases) in [
            "ControlLeft": ["ctrl", "control"], "ShiftLeft": ["shift"], "AltLeft": ["alt", "option"],
            "MetaLeft": ["meta", "win", "super", "cmd", "command"], "Enter": ["return"],
            "Delete": ["forwarddelete"], "Escape": ["esc"], "Space": ["spacebar"],
            "ArrowLeft": ["left"], "ArrowRight": ["right"], "ArrowUp": ["up"], "ArrowDown": ["down"],
            "PageUp": ["page_up"], "PageDown": ["page_down"], "ContextMenu": ["menu"],
            "AudioVolumeUp": ["volumeup"], "AudioVolumeDown": ["volumedown"], "AudioVolumeMute": ["volumemute"]
        ] {
            for alias in aliases { result[alias] = canonical.lowercased() }
        }
        for letter in "abcdefghijklmnopqrstuvwxyz" { result[String(letter)] = "key\(letter)" }
        for digit in 0...9 { result[String(digit)] = "digit\(digit)" }
        return result
    }()

    private static let table: [String: Self] = {
        var result: [String: Self] = [:]
        func add(_ name: String, _ scan: UInt32, modifier: Bool = false) {
            result[name.lowercased()] = Self(name: name, scancode: scan, isModifier: modifier)
        }
        for (name, scan): (String, UInt32) in [
            ("ControlLeft", 0x1D), ("ControlRight", 0x11D), ("ShiftLeft", 0x2A), ("ShiftRight", 0x36),
            ("AltLeft", 0x38), ("AltRight", 0x138), ("MetaLeft", 0x15B), ("MetaRight", 0x15C)
        ] { add(name, scan, modifier: true) }
        let letters: [UInt32] = [0x1E,0x30,0x2E,0x20,0x12,0x21,0x22,0x23,0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19,0x10,0x13,0x1F,0x14,0x16,0x2F,0x11,0x2D,0x15,0x2C]
        for (letter, scan) in zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ", letters) { add("Key\(letter)", scan) }
        for digit in 0...9 { add("Digit\(digit)", digit == 0 ? 0x0B : UInt32(digit + 1)) }
        for number in 1...24 {
            let scan = number <= 10 ? UInt32(0x3A + number) : number <= 12 ? UInt32(0x57 + number - 11) : UInt32(0x64 + number - 13)
            add("F\(number)", scan)
        }
        let keypad: [UInt32] = [0x52,0x4F,0x50,0x51,0x4B,0x4C,0x4D,0x47,0x48,0x49]
        for digit in 0...9 { add("Numpad\(digit)", keypad[digit]) }
        for (name, scan): (String, UInt32) in [
            ("Enter",0x1C), ("NumpadEnter",0x11C), ("Backspace",0x0E), ("Delete",0x153),
            ("Escape",0x01), ("Tab",0x0F), ("Space",0x39), ("ArrowLeft",0x14B), ("ArrowRight",0x14D),
            ("ArrowUp",0x148), ("ArrowDown",0x150), ("Home",0x147), ("End",0x14F),
            ("PageUp",0x149), ("PageDown",0x151), ("Insert",0x152), ("Minus",0x0C), ("Equal",0x0D),
            ("BracketLeft",0x1A), ("BracketRight",0x1B), ("Backslash",0x2B), ("Semicolon",0x27),
            ("Quote",0x28), ("Backquote",0x29), ("Comma",0x33), ("Period",0x34), ("Slash",0x35),
            ("IntlBackslash",0x56), ("IntlYen",0x7D), ("IntlRo",0x73), ("NumpadDecimal",0x53),
            ("NumpadAdd",0x4E), ("NumpadSubtract",0x4A), ("NumpadMultiply",0x37), ("NumpadDivide",0x135),
            ("NumpadEqual",0x59), ("NumpadComma",0x7E), ("CapsLock",0x3A), ("NumLock",0x45),
            ("ScrollLock",0x46), ("ContextMenu",0x15D), ("PrintScreen",0x137), ("Pause",0x146),
            ("AudioVolumeUp",0x130), ("AudioVolumeDown",0x12E), ("AudioVolumeMute",0x120),
            ("Lang1",0x72), ("Lang2",0x71), ("Convert",0x79), ("NonConvert",0x7B)
        ] { add(name, scan) }
        return result
    }()
}
