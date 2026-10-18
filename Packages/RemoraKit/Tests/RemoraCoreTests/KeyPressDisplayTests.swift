import Testing
import RemoraCore

@Test func keyPressDisplayUsesRemoteModifierNames() throws {
    var display = KeyPressDisplay()
    func press(_ name: String) throws -> KeyPressDisplay.Press? {
        var result: KeyPressDisplay.Press?
        for key in try PhysicalKey.chord(name) { result = display.key(scancode: key.scancode, down: true) }
        return result
    }
    #expect(try press("Ctrl+Alt+Delete") == .init(text: "Ctrl+Alt+Delete", isText: false))
    display = KeyPressDisplay()
    #expect(try press("Command+r")?.text == "Win+R")
    display = KeyPressDisplay()
    #expect(try press("ControlRight+c")?.text == "Ctrl+C")
}

@Test func keyPressDisplayPreservesTypedTextAndNamesSpecialKeys() throws {
    var display = KeyPressDisplay()
    #expect(display.key(scancode: 0x1E, down: true)?.text == "a")
    #expect(display.key(scancode: 0x1E, down: false) == nil)
    #expect(display.key(scancode: 0x2A, down: true) == nil)
    #expect(display.key(scancode: 0x02, down: true) == .init(text: "!", isText: true))
    #expect(display.key(scancode: 0x10, down: true, characters: "Ä")?.text == "Ä")
    for (name, expected) in [("Return", "Return"), ("Esc", "Esc"), ("Tab", "Tab"), ("Left", "Left"), ("F24", "F24")] {
        display = KeyPressDisplay()
        #expect(display.key(scancode: try PhysicalKey.chord(name)[0].scancode, down: true) == .init(text: expected, isText: false))
    }
    #expect(display.key(scancode: 0xFFFF, down: true) == nil)
}

@Test func unicodeInputNamesControlCharacters() {
    #expect(KeyPressDisplay.text("\t") == .init(text: "Tab", isText: false))
    #expect(KeyPressDisplay.text("\n") == .init(text: "Return", isText: false))
    #expect(KeyPressDisplay.text("é") == .init(text: "é", isText: true))
}

@Test func feedbackCombinesTextAndCountsRepeatedChords() {
    let overlays = SessionOverlayState()
    overlays.configure(showPointerInRecordings: true, showKeyPresses: true, showAgentPointer: true, scale: 1)
    overlays.receive(.human, .key(scancode: 0x23, down: true, characters: "h"))
    overlays.receive(.agent, .text("ello"))
    #expect(overlays.snapshot().keyText == "hello")
    for _ in 0..<3 {
        overlays.receive(.agent, .key(scancode: 0x0F, down: true))
        overlays.receive(.agent, .key(scancode: 0x0F, down: false))
    }
    let last = overlays.snapshot()
    #expect(last.keyText == "Tab ×3")
    #expect(overlays.snapshot(at: last.time + 1.6).keyText == nil)
    overlays.configure(showPointerInRecordings: true, showKeyPresses: false, showAgentPointer: true, scale: 1)
    overlays.receive(.agent, .text("disabled"))
    overlays.configure(showPointerInRecordings: true, showKeyPresses: true, showAgentPointer: true, scale: 1)
    #expect(overlays.snapshot().keyText == nil)
}
