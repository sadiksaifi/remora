import Carbon

@MainActor enum KeyboardType {
    static var isISO: Bool { KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO }
}
