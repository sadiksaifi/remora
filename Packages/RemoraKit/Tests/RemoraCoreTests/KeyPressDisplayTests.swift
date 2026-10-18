import Testing
import Foundation
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

@Test func pillLaysOutKeysTextAndRepeatsAtAnySize() throws {
    let chord = try #require(KeyPressPill(text: "Ctrl+Alt+Delete", isText: false, scale: 1))
    #expect(chord.items.map(\.kind) == [.key, .key, .key] && chord.items.map(\.text) == ["Ctrl", "Alt", "Delete"])
    let repeated = try #require(KeyPressPill(text: "Tab ×3", isText: false, scale: 1))
    #expect(repeated.items.map(\.text) == ["Tab", "×3"] && repeated.items.last?.kind == .count)
    #expect(KeyPressPill(text: " ", isText: true, scale: 1)?.items.map(\.text) == ["Space"])
    #expect(KeyPressPill(text: "a+b", isText: true, scale: 1)?.items.map(\.kind) == [.text])
    let large = try #require(KeyPressPill(text: "Ctrl+Alt+Delete", isText: false, scale: 2))
    // SF Pro tracks tighter at larger optical sizes, so widths scale slightly less than heights.
    #expect(large.size.height == 2 * chord.size.height && abs(large.size.width / chord.size.width - 2) < 0.1)
}

@Test(arguments: [1.0, 2.0]) func screenPointerKeepsPointSizes(connectionScale: Double) throws {
    let overlays = SessionOverlayState()
    overlays.configure(showPointerInRecordings: true, showKeyPresses: true, showAgentPointer: true,
        scale: connectionScale, keyPressSize: 1.5)
    overlays.receive(.agent, .pointer(.init(x: 400, y: 200), .left))
    overlays.receive(.agent, .text("hello"))
    let state = overlays.snapshot()
    let drawing = SessionOverlayDrawing()
    for pointsPerPixel: CGFloat in [0.25, 0.5, 1, 2] {
        let sprites = drawing.sprites(state, recording: false, pointsPerPixel: pointsPerPixel)
        let ring = try #require(sprites.first)
        let arrow = try #require(sprites.last)
        #expect(ring.rect.width * pointsPerPixel == 32)
        #expect(arrow.rect.width * pointsPerPixel == 24 && arrow.rect.height * pointsPerPixel == 27)
        #expect((arrow.rect.minX + 4 / pointsPerPixel) * pointsPerPixel == 400.5 * pointsPerPixel)
    }
    let recorded = try #require(drawing.sprites(state, recording: true).last)
    #expect(recorded.rect.height == 27 * CGFloat(connectionScale))
}

@Test(arguments: [1.0, 2.0], [0.75, 1.0, 1.5, 2.0])
func screenPillScalesWithRecordedDesktop(connectionScale: Double, keySize: Double) throws {
    let overlays = SessionOverlayState()
    overlays.configure(showPointerInRecordings: true, showKeyPresses: true, showAgentPointer: true,
        scale: connectionScale, keyPressSize: keySize)
    overlays.receive(.agent, .text("hello"))
    let state = overlays.snapshot()
    let desktop = CGSize(width: 3840, height: 2160)
    let movie = try #require(KeyPressPill.placed(state, desktop: desktop))
    let recorded = try #require(SessionOverlayDrawing().keyPress(state, desktop: desktop))
    #expect(movie.frame == recorded.frame)
    #expect(movie.pill.size.height == 88 * keySize && desktop.height - movie.frame.maxY == 128)
    for pointsPerPixel: CGFloat in [0.25, 0.5, 1, 2] {
        let screen = try #require(KeyPressPill.placed(state, desktop: desktop, pointsPerPixel: pointsPerPixel))
        let transform = CGAffineTransform(scaleX: pointsPerPixel, y: pointsPerPixel)
        #expect(screen.frame == recorded.frame.applying(transform))
        #expect(screen.pill.size == movie.pill.size.applying(transform))
        #expect(screen.pill.scale == movie.pill.scale * pointsPerPixel)
        #expect(screen.pill.items.map(\.frame) == movie.pill.items.map { $0.frame.applying(transform) })
    }
    let screen = try #require(KeyPressPill.placed(state, desktop: desktop, pointsPerPixel: 0.25))
    #expect(screen.pill.size.height == 22 * keySize && 540 - screen.frame.maxY == 32)
}

@Test func fitToWindowRetinaPillKeepsStandardPointSize() throws {
    let overlays = SessionOverlayState()
    overlays.configure(showPointerInRecordings: true, showKeyPresses: true, showAgentPointer: true, scale: 2)
    overlays.receive(.agent, .text("hello"))
    let screen = try #require(KeyPressPill.placed(overlays.snapshot(),
        desktop: CGSize(width: 1920, height: 1080), pointsPerPixel: 0.5))
    #expect(screen.pill.size.height == 44 && screen.pill.scale == 1)
    #expect(540 - screen.frame.maxY == 64)
}
