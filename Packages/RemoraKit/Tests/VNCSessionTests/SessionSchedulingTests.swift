import Foundation
import OSLog
import RemoraCore
import Testing

@testable import VNCSession

/// A real network peer with numeric reports. Its reader never waits for frame delivery.
final class SessionPeer: @unchecked Sendable {
    let process = Process()
    let port: UInt16
    private let input = Pipe()
    private let lock = NSLock()
    private var reports: [[String: Any]] = []

    init(arguments: [String] = []) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments =
            ["-u", try #require(Bundle.module.url(forResource: "session_peer", withExtension: "py", subdirectory: "Fixtures")).path] + arguments
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        @Sendable func line() throws -> Data {
            var data = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { data.append(byte) }
            return data
        }
        let hello = try #require(JSONSerialization.jsonObject(with: line()) as? [String: Any])
        port = UInt16(try #require(hello["port"] as? Int))
        Thread { [self] in
            while let data = try? line(), !data.isEmpty {
                if let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    lock.withLock { reports.append(report) }
                }
            }
        }.start()
    }
    func command(_ action: String) throws { try input.fileHandleForWriting.write(contentsOf: Data("{\"action\":\"\(action)\"}\n".utf8)) }
    func events(_ event: String) -> [[String: Any]] { lock.withLock { reports.filter { $0["event"] as? String == event } } }
    func wait(_ event: String, count: Int = 1) async throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while ContinuousClock.now < deadline {
            if let result = events(event).dropFirst(count - 1).first { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PeerTimeout()
    }
    func resetAndWait() {
        try? command("reset")
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while events("reset").isEmpty && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
    }
    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
    struct PeerTimeout: Error {}
}
final class MarkerFrames: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var markers: [UInt8] = []
    func consume(_ frame: BorrowedFrame) { lock.withLock { markers.append(frame.pixels.load(as: UInt8.self)) } }
    var values: [UInt8] { lock.withLock { markers } }
}

@Test @MainActor func vncDisplayDemandOnlyRefreshesOnARealResume() async throws {
    let peer = try SessionPeer()
    defer { peer.stop() }
    let frames = MarkerFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(
        configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
        certificateStoreURL: pins)
    defer { session.disconnect() }
    session.setDisplayUpdatesEnabled(true)  // Startup owns its one full request.
    session.connect()
    _ = try await peer.wait("request", count: 2)
    #expect(frames.values == [1])
    for _ in 0..<3 {
        session.setDisplayUpdatesEnabled(true)
        try await Task.sleep(for: .milliseconds(60))
    }
    try peer.command("counts")
    let repeated = try await peer.wait("counts")
    #expect(repeated["full"] as? Int == 1)
    session.setDisplayUpdatesEnabled(false)
    session.setDisplayUpdatesEnabled(false)
    session.setDisplayUpdatesEnabled(true)  // Off/on coalesced before the worker runs.
    try await Task.sleep(for: .milliseconds(80))
    try peer.command("counts")
    let resumed = try await peer.wait("counts", count: 2)
    #expect(resumed["full"] as? Int == 2)
    let agent = try #require(session.beginAgentInput())
    try await agent.send(.key(try PhysicalKey.chord("KeyA")[0], down: true), deadline: .now.advanced(by: .seconds(2)))
    #expect(await agent.finish())
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !frames.values.contains(2), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(frames.values.last == 2)
    #expect((resumed["incremental"] as? Int ?? 0) > 0)
}

@Test @MainActor func vncInputReachesTheWireBeforeAnIncompleteFrameFinishes() async throws {
    for mode in ["paced-small", "paced-large", "unpaced"] {
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
        _ = try await peer.wait("request")
        try peer.command("start")
        _ = try await peer.wait("body_started")
        try await Task.sleep(for: .milliseconds(50))
        for index in 0..<64 {
            session.sendPointer(position: .init(x: UInt16(index % 16), y: UInt16(index / 16)), buttons: [])
        }
        _ = try await peer.wait("pointer", count: 64)
        #expect(
            peer.events("pointer").prefix(64).enumerated().allSatisfy { index, event in
                event["x"] as? Int == index % 16 && event["y"] as? Int == index / 16
            })
        session.sendKey(.init(keyCode: 56, isDown: true))  // Human Shift owns the wire key.
        let agent = try #require(session.beginAgentInput())
        try await agent.send(.key(try PhysicalKey.chord("ShiftLeft")[0], down: true), deadline: .now.advanced(by: .seconds(3)))
        agent.cancel()
        do {
            try await agent.send(.key(try PhysicalKey.chord("KeyB")[0], down: true), deadline: .now.advanced(by: .seconds(1)))
            Issue.record("A canceled agent must not admit another key.")
        } catch {}
        #expect(await agent.finish())
        #expect(peer.events("key").allSatisfy { $0["down"] as? Int == 1 })
        session.releaseHumanInput()
        _ = try await peer.wait("key", count: 2)
        let key = try await peer.wait("key")
        let body = try await peer.wait("body_done")
        let keyMS = try #require(key["ms"] as? Int)
        let bodyMS = try #require(body["ms"] as? Int)
        print("Input scheduling mode=\(mode) key_ms=\(keyMS) body_done_ms=\(bodyMS)")
        if mode != "unpaced" { #expect(keyMS < bodyMS - 200) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while frames.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(frames.values.count == 1)
        #expect(peer.events("key").count == 2)
        #expect(peer.events("key").allSatisfy { $0["symbol"] as? Int == 65505 })
        #expect(peer.events("key").last?["down"] as? Int == 0)
        _ = try await peer.wait("pointer", count: 66)
        #expect(peer.events("pointer").count == 66)  // 64 events plus agent and human release.
        #expect(peer.events("error").isEmpty)
    }
}

@Test @MainActor func vncInputWriteFailureDuringAFrameKeepsItsOwnFailureReason() async throws {
    for mode in ["paced-small", "paced-large"] {
        let peer = try SessionPeer(arguments: [mode])
        defer { peer.stop() }
        let frames = MarkerFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
            inputFeedback: { _, _ in
                // Reset at a real acknowledged write boundary. The next queued
                // write fails while the same worker is still inside the frame read.
                peer.resetAndWait()
            }, certificateStoreURL: pins)
        defer { session.disconnect() }
        let fallback = Task {
            do {
                try await Task.sleep(for: .seconds(3))
                session.disconnect()
            } catch {}
        }
        defer { fallback.cancel() }
        session.connect()
        _ = try await peer.wait("request")
        try peer.command("start")
        _ = try await peer.wait("body_started")
        try await Task.sleep(for: .milliseconds(30))
        session.sendKey(.init(keyCode: 56, isDown: true))
        session.sendKey(.init(keyCode: 56, isDown: false))
        var reason: DisconnectReason?
        for await event in session.events {
            if case .stateChanged(.disconnected(let failure)) = event { reason = failure }
        }
        #expect(reason == .protocolError("The VNC input submission failed. The transport was closed."))
        #expect(!peer.events("reset").isEmpty)
        #expect(frames.values.isEmpty)
    }
}

@Test @MainActor func vncSuccessfulInReadInputPreservesTheLaterReadFailureContext() async throws {
    let started = Date()
    let peer = try SessionPeer(arguments: ["paced-small"])
    defer { peer.stop() }
    let frames = MarkerFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(
        configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames,
        certificateStoreURL: pins)
    defer { session.disconnect() }
    session.connect()
    _ = try await peer.wait("request")
    try peer.command("start")
    _ = try await peer.wait("body_started")
    try await Task.sleep(for: .milliseconds(30))
    let agent = try #require(session.beginAgentInput())
    try await agent.send(.key(try PhysicalKey.chord("KeyA")[0], down: true), deadline: .now.advanced(by: .seconds(1)))
    #expect(await agent.finish())
    _ = try await peer.wait("key", count: 2)
    try peer.command("close")
    for await _ in session.events {}
    #expect(frames.values.isEmpty)
    let attemptID = session.handshakeAttemptID
    let messages = try await Task.detached {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "dev.sadiksaifi.Remora", "VNC")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var messages: [String] = []
        repeat {
            messages = try store.getEntries(at: store.position(date: started), matching: predicate)
                .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
                .filter { $0.hasPrefix("Runtime failure attempt=\(attemptID) ") }
            if !messages.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return messages
    }.value
    #expect(messages.count == 1)
    let message = try #require(messages.first)
    print("After in-read input: \(message)")
    #expect(message.contains("stage=6 failure=9 operation=1"))
    #expect(message.contains("message=0 rect_index=0 rect_count=1 encoding=16"))
    #expect(message.contains("width=16 height=16 fb_width=16 fb_height=16 callbacks=0 cancelled=0"))
}
