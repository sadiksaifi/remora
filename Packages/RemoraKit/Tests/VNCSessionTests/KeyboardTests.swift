import Foundation
import RemoraCore
import Testing
@testable import VNCSession

@Test func vncKeyboardPreservesPhysicalModifiersAndExtendedCodes() throws {
    let right = try PhysicalKey.chord("ArrowRight")[0]
    let print = try PhysicalKey.chord("PrintScreen")[0]
    let pause = try PhysicalKey.chord("Pause")[0]
    #expect(VNCKey(physical: right)?.keysym == 0xff53)
    #expect(VNCKey(physical: right)?.code == 0xcd)
    #expect(VNCKey(physical: print)?.code == 0x54)
    #expect(VNCKey(physical: pause)?.code == 0xc6)
    #expect(VNCKey(physical: try PhysicalKey.chord("ControlRight")[0])?.keysym == 0xffe4)
    #expect(VNCKey(physical: try PhysicalKey.chord("MetaLeft")[0])?.keysym == 0xffeb)
    #expect(VNCKey(physical: try PhysicalKey.chord("AltRight")[0])?.keysym == 0xffea)
    #expect(VNCKey(scalar: "ä").keysym == 0xe4)
    #expect(VNCKey(scalar: "界").keysym == 0x0100754c)
    #expect(VNCKey(scalar: "€").keysym == 0x20ac)
    #expect(VNCKey(scalar: "α").keysym == 0x07e1)
    #expect(VNCKey(physical: try PhysicalKey.chord("Lang1")[0])?.keysym == 0xff31)
}

private final class Wire: VNCInputTransport {
    var keys: [(UInt32, Bool)] = []
    var pointers: [UInt8] = []
    func key(_ key: VNCKey, down: Bool) -> Bool { keys.append((key.keysym, down)); return true }
    func pointer(_ point: RemotePoint, mask: UInt8) -> Bool { pointers.append(mask); return true }
}

@Test func vncFocusReleasePreservesAgentKeysAndButtons() throws {
    var input = VNCInputState()
    let wire = Wire()
    let key = try PhysicalKey.chord("ShiftLeft")[0]
    #expect({ input.apply(.key(key, down: true), source: .agent, wire: wire) }())
    #expect({ input.apply(.key(key, down: true), source: .human, wire: wire) }())
    #expect({ input.apply(.pointer(.init(x: 4, y: 5), .left), source: .agent, wire: wire) }())
    #expect({ input.apply(.pointer(.init(x: 4, y: 5), .right), source: .human, wire: wire) }())
    #expect({ input.release(.human, wire: wire) }())
    #expect(!wire.keys.contains { !$0.1 })
    #expect(wire.pointers.last == 1)
    #expect({ input.release(.agent, wire: wire) }())
    #expect(wire.keys.filter { !$0.1 }.count == 1)
    #expect(wire.pointers.last == 0)
}

@Test func vncWheelAccumulatesFractionsAndRetainsHeldButtons() {
    var input = VNCInputState()
    let wire = Wire()
    #expect({ input.apply(.pointer(.init(x: 1, y: 2), .left), source: .human, wire: wire) }())
    #expect({ input.apply(.wheel(.init(vertical: 60, horizontal: 0)), source: .human, wire: wire) }())
    #expect(wire.pointers.count == 1)
    #expect({ input.apply(.wheel(.init(vertical: 60, horizontal: -120)), source: .human, wire: wire) }())
    #expect(wire.pointers == [1, 9, 1, 33, 1])
}

@Test @MainActor func vncWheelTurnsAtItsOwnPositionAndKeepsHeldButtons() async throws {
    let peer = try SessionPeer()
    defer { peer.stop() }
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let feedback = PointerFeedback()
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: MarkerFrames(),
                             inputFeedback: { source, event in feedback.receive(source, event) }, certificateStoreURL: pins)
    defer { session.disconnect() }
    session.connect()
    _ = try await peer.wait("request")
    session.sendPointer(position: .init(x: 1, y: 2), buttons: .left)
    session.sendWheel(.init(vertical: 120, horizontal: 0), at: .init(x: 9, y: 7))
    _ = try await peer.wait("pointer", count: 3)
    let pointers = peer.events("pointer").map { [$0["x"] as? Int, $0["y"] as? Int, $0["mask"] as? Int] }
    #expect(pointers == [[1, 2, 1], [9, 7, 9], [9, 7, 1]])
    // Recordings draw the pointer from feedback, so the pulses' movement is published with the held button.
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while feedback.values.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(feedback.values == ["human 1,2 1", "human 9,7 1"])
}

private final class PointerFeedback: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func receive(_ source: InputSource, _ event: SessionInputFeedback) {
        guard case .pointer(let point, let buttons) = event else { return }
        lock.withLock { events.append("\(source) \(point.x),\(point.y) \(buttons.rawValue)") }
    }
    var values: [String] { lock.withLock { events } }
}
