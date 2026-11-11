import Foundation
import RemoraCore
import Testing
import VNCSession

@Test @MainActor func vncSingleZRLERequestsTheNextUpdateBeforeItsBodyFinishes() async throws {
    for mode in ["early-small", "early-large"] {
        let peer = try SessionPeer(arguments: [mode])
        defer { peer.stop() }
        let frames = MarkerFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
            certificateStoreURL: pins)
        defer { session.disconnect() }
        session.connect()
        _ = try await peer.wait("request", count: 2)  // Startup full response and trailing incremental.
        #expect(frames.values == [1])
        try peer.command("start")
        _ = try await peer.wait("body_started")
        let agent = try #require(session.beginAgentInput())
        try await agent.send(.key(try PhysicalKey.chord("KeyA")[0], down: true), deadline: .now.advanced(by: .seconds(2)))
        #expect(await agent.finish())
        _ = try await peer.wait("key", count: 2)
        let next = try await peer.wait("request", count: 3)
        #expect(next["body_finished"] as? Bool == false)
        let body = try await peer.wait("body_done")
        #expect(try #require(peer.events("key").last?["ms"] as? Int) < #require(body["ms"] as? Int) - 200)
        let marker = try #require(try await peer.wait("marker")["value"] as? Int)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while frames.values.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(frames.values == [1, UInt8(marker)])
        try await Task.sleep(for: .milliseconds(80))
        try peer.command("counts")
        let counts = try await peer.wait("counts")
        #expect(counts["full"] as? Int == 1)
        #expect(counts["incremental"] as? Int == 2)  // Early write replaces the trailer.
        #expect(peer.events("pointer").count == 1)
        #expect(peer.events("error").isEmpty)
        session.disconnect()
    }
}

@Test @MainActor func vncEarlyRequestOverlapsPeerPreparationAndThenDefers() async throws {
    let peer = try SessionPeer(arguments: ["prepare"])
    defer { peer.stop() }
    let frames = MarkerFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(
        configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
        certificateStoreURL: pins)
    defer { session.disconnect() }
    session.connect()
    _ = try await peer.wait("response_done", count: 3)
    let preparation = try await peer.wait("preparation", count: 2)
    let firstDone = try await peer.wait("response_body_end")
    #expect(try #require(preparation["at_us"] as? Int) < #require(firstDone["at_us"] as? Int))
    let headers = peer.events("response_header")
    let interval = try #require(headers[1]["at_us"] as? Int) - #require(headers[0]["at_us"] as? Int)
    print("Early request preparation overlap start_to_start_us=\(interval) wait_us=200000 transfer_us=300000")
    #expect(interval < 450_000)  // Secondary bound: max(wait, transfer), rather than their sum.
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while frames.values.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(frames.values.count == 4)
    _ = try await peer.wait("request", count: 5)
    try await Task.sleep(for: .milliseconds(150))  // Peer deliberately defers unchanged damage.
    #expect(peer.events("request").count == 5)
    #expect(peer.events("error").isEmpty)
}

private final class EdgeFrames: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(DesktopSize, UInt8)] = []
    func consume(_ frame: BorrowedFrame) {
        let edge = frame.pixels.load(fromByteOffset: (frame.height - 1) * frame.stride + (frame.width - 1) * 4, as: UInt8.self)
        lock.withLock { records.append((.init(width: frame.width, height: frame.height), edge)) }
    }
    var last: (DesktopSize, UInt8)? { lock.withLock { records.last } }
}

@Test @MainActor func vncCompoundAndControlUpdatesKeepTheTrailingPathAndRepairGeometry() async throws {
    for mode in ["early-cursor", "early-last", "early-empty", "early-geometry"] {
        let peer = try SessionPeer(arguments: [mode])
        defer { peer.stop() }
        let frames = EdgeFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
            certificateStoreURL: pins)
        defer { session.disconnect() }
        session.connect()
        _ = try await peer.wait("request", count: 2)
        try peer.command("start")
        _ = try await peer.wait("body_done")
        let next = try await peer.wait("request", count: 3)
        #expect(next["body_finished"] as? Bool == true)
        if mode == "early-geometry" {
            _ = try await peer.wait("request", count: 5)
            #expect(next["w"] as? Int == 17 && next["h"] as? Int == 17)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while frames.last?.0 != .init(width: 17, height: 17), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(frames.last?.0 == .init(width: 17, height: 17))
            #expect(frames.last?.1 == 7)  // The newly added edge was actually decoded.
        }
        try await Task.sleep(for: .milliseconds(80))
        try peer.command("counts")
        let counts = try await peer.wait("counts")
        #expect(counts["full"] as? Int == (mode == "early-geometry" ? 2 : 1))
        #expect(counts["incremental"] as? Int == (mode == "early-geometry" ? 3 : 2))
        #expect(peer.events("error").isEmpty)
    }
}

@Test @MainActor func vncImmediateRefreshSurvivesBothCoalescedAndSeparateReplies() async throws {
    for mode in ["refresh", "refresh-separate"] {
        let peer = try SessionPeer(arguments: [mode])
        defer { peer.stop() }
        let frames = MarkerFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
            certificateStoreURL: pins)
        defer { session.disconnect() }
        session.connect()
        _ = try await peer.wait("request", count: 2)
        session.setDisplayUpdatesEnabled(false)
        session.setDisplayUpdatesEnabled(true)
        #expect(session.awaitsRedraw)
        // Neither peer sends incremental damage until explicitly instructed.
        _ = try await peer.wait("request", count: 4)
        #expect(frames.values == [1, 1])  // A fresh revision, despite unchanged pixels.
        #expect(!session.awaitsRedraw)
        try peer.command("damage")
        _ = try await peer.wait("request", count: 5)
        #expect(frames.values == [1, 1, 3])
        try peer.command("counts")
        let counts = try await peer.wait("counts")
        #expect(counts["full"] as? Int == 2)
        #expect(counts["incremental"] as? Int == 3)
        #expect(peer.events("error").isEmpty)
    }
}

@Test @MainActor func vncEarlyRequestIsNotRepeatedAfterDecodeFailureOrCancellation() async throws {
    for cancelled in [false, true] {
        let peer = try SessionPeer(arguments: ["early-small"])
        defer { peer.stop() }
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: MarkerFrames(),
            certificateStoreURL: pins)
        defer { session.disconnect() }
        session.connect()
        _ = try await peer.wait("request", count: 2)
        try peer.command(cancelled ? "start" : "invalid")
        _ = try await peer.wait("request", count: 3)  // Sent before the later failure/stop.
        if cancelled { session.disconnect() }
        for await _ in session.events {}
        try await Task.sleep(for: .milliseconds(50))
        #expect(peer.events("request").count == 3)
    }
}
