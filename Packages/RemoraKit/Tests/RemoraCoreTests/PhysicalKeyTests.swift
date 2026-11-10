import RemoraCore
import Testing

@Test func physicalChordsPreserveSidesAndOrder() throws {
    #expect(try PhysicalKey.chord("Ctrl+Shift+Escape").map(\.scancode) == [0x1D, 0x2A, 0x01])
    #expect(try PhysicalKey.chord("AltRight+ControlRight+Delete").map(\.scancode) == [0x138, 0x11D, 0x153])
    #expect(try PhysicalKey.chord("CMD+r").map(\.scancode) == [0x15B, 0x13])
    #expect(try PhysicalKey.chord("A") == PhysicalKey.chord("KeyA"))
    #expect(try PhysicalKey.chord("NumpadEnter").first?.scancode == 0x11C)
    #expect(try PhysicalKey.chord("F13").first?.scancode == 0x64)
    #expect(try PhysicalKey.chord("F24").first?.scancode == 0x6F)
    #expect(try PhysicalKey.chord("Pause").first?.isPause == true)
}

@Test func physicalChordsRejectAmbiguityAndImpossibleCombinations() {
    for chord in ["", "Del", "Fn", "ControlOrMeta", "Ctrl+ControlLeft+a", "a+b", "a+Ctrl", "Ctrl+", "+", "F25", "Ctrl+Shift"] {
        #expect(throws: (any Error).self) { try PhysicalKey.chord(chord) }
    }
    #expect(throws: (any Error).self) { try PhysicalKey.chord("Shift+a", modifiersOnly: true) }
}

@Test func pointerModifiersAllowDistinctSides() throws {
    #expect(try PhysicalKey.chord("Shift+ControlRight", modifiersOnly: true).map(\.scancode) == [0x2A, 0x11D])
    #expect(try PhysicalKey.chord("Option").first?.scancode == 0x38)
}
