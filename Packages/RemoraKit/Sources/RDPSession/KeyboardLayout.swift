import CFreeRDPBridge
import Carbon

/// Snapshot once for this connection. Input source IDs are stable across UI languages.
@MainActor
enum KeyboardLayout {
    static func isISO() -> Bool {
        KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO
    }

    static func current() -> UInt32 {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else {
            return 0x0409
        }
        let identifier = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        let name: String
        switch identifier {
        case "com.apple.keylayout.US", "com.apple.keylayout.ABC": name = "United States - English"
        case "com.apple.keylayout.British": name = "United Kingdom"
        case "com.apple.keylayout.German": name = "German"
        case "com.apple.keylayout.French": name = "French"
        case "com.apple.keylayout.Spanish", "com.apple.keylayout.Spanish-ISO": name = "Spanish"
        case "com.apple.keylayout.Italian": name = "Italian"
        case "com.apple.keylayout.Portuguese": name = "Portuguese"
        case "com.apple.keylayout.Brazilian": name = "Portuguese (Brazilian ABNT)"
        case "com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin": name = "Russian"
        case "com.apple.keylayout.Swedish": name = "Swedish"
        case "com.apple.keylayout.Norwegian": name = "Norwegian"
        case "com.apple.keylayout.Danish": name = "Danish"
        case "com.apple.keylayout.Finnish": name = "Finnish"
        case "com.apple.keylayout.Dutch": name = "Dutch"
        case "com.apple.keylayout.Polish": name = "Polish (Programmers)"
        case "com.apple.keylayout.SwissGerman": name = "Swiss German"
        case "com.apple.keylayout.SwissFrench": name = "Swiss French"
        case "com.apple.keylayout.Dvorak": name = "United States-Dvorak"
        case "com.apple.keylayout.USInternational-PC": name = "United States-International"
        default:
            if identifier.hasPrefix("com.apple.inputmethod.Kotoeri") {
                name = "Japanese"
            } else if identifier.hasPrefix("com.apple.inputmethod.Korean") {
                name = "Korean"
            } else if identifier.hasPrefix("com.apple.inputmethod.SCIM") {
                return 0x0804
            } else if identifier.hasPrefix("com.apple.inputmethod.TCIM") {
                return 0x0404
            } else {
                return 0x0409
            }
        }
        return name.withCString { rm_rdp_keyboard_layout($0) }
    }
}
