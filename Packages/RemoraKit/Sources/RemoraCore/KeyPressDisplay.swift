import Foundation

/// Names physical keys as the remote receives them. AppKit can supply layout-aware text.
public struct KeyPressDisplay: Sendable {
    public struct Press: Sendable, Equatable {
        public let text: String
        public let isText: Bool
        public init(text: String, isText: Bool) { self.text = text; self.isText = isText }
    }

    private var modifiers: Set<PhysicalKey> = []
    public init() {}

    public mutating func key(scancode: UInt32, down: Bool, characters: String? = nil) -> Press? {
        guard let key = PhysicalKey(scancode: scancode) else { return nil }
        if key.isModifier {
            if down { modifiers.insert(key) } else { modifiers.remove(key) }
            return nil
        }
        guard down else { return nil }
        let names = Set(modifiers.map { Self.name($0) })
        let shortcut = !names.subtracting(["Shift"]).isEmpty
        if !shortcut, let text = characters ?? Self.literal(key, shift: names.contains("Shift")),
           !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            return Press(text: text, isText: true)
        }
        let prefix = ["Ctrl", "Alt", "Shift", "Win"].filter { names.contains($0) }
        return Press(text: (prefix + [Self.name(key)]).joined(separator: "+"), isText: false)
    }

    public static func text(_ text: String) -> Press {
        switch text {
        case "\t": Press(text: "Tab", isText: false)
        case "\r", "\n", "\r\n": Press(text: "Return", isText: false)
        case "\u{1B}": Press(text: "Esc", isText: false)
        case "\u{8}": Press(text: "Backspace", isText: false)
        default: Press(text: text, isText: true)
        }
    }

    private static func name(_ key: PhysicalKey) -> String {
        switch key.name {
        case "ControlLeft", "ControlRight": "Ctrl"
        case "AltLeft", "AltRight": "Alt"
        case "ShiftLeft", "ShiftRight": "Shift"
        case "MetaLeft", "MetaRight": "Win"
        case "Enter": "Return"
        case "Escape": "Esc"
        default: key.name.hasPrefix("Key") ? String(key.name.dropFirst(3))
            : key.name.hasPrefix("Digit") ? String(key.name.dropFirst(5))
            : key.name.hasPrefix("Arrow") ? String(key.name.dropFirst(5)) : key.name
        }
    }

    private static func literal(_ key: PhysicalKey, shift: Bool) -> String? {
        if key.name.hasPrefix("Key") {
            let letter = String(key.name.dropFirst(3))
            return shift ? letter : letter.lowercased()
        }
        let literals: [String: (String, String)] = [
            "Digit0": ("0", ")"), "Digit1": ("1", "!"), "Digit2": ("2", "@"), "Digit3": ("3", "#"),
            "Digit4": ("4", "$"), "Digit5": ("5", "%"), "Digit6": ("6", "^"), "Digit7": ("7", "&"),
            "Digit8": ("8", "*"), "Digit9": ("9", "("), "Space": (" ", " "), "Minus": ("-", "_"),
            "Equal": ("=", "+"), "BracketLeft": ("[", "{"), "BracketRight": ("]", "}"), "Backslash": ("\\", "|"),
            "Semicolon": (";", ":"), "Quote": ("'", "\""), "Backquote": ("`", "~"), "Comma": (",", "<"),
            "Period": (".", ">"), "Slash": ("/", "?")
        ]
        return literals[key.name].map { shift ? $0.1 : $0.0 }
    }
}
