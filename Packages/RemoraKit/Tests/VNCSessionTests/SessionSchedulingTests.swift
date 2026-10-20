import Foundation
import RemoraCore
import Testing
import VNCSession

/// A real network peer with numeric reports. Its reader never waits for frame delivery.
final class SessionPeer: @unchecked Sendable {
    let process = Process()
    let port: UInt16
    private let input = Pipe()
    private let lock = NSLock()
    private var reports: [[String: Any]] = []

    init(arguments: [String] = []) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", try #require(Bundle.module.url(forResource: "session_peer", withExtension: "py", subdirectory: "Fixtures")).path] + arguments
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        func line() throws -> Data {
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
            if let result = events(event).dropFirst(count-1).first { return result }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PeerTimeout()
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
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
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames, certificateStoreURL: pins)
    defer { session.disconnect() }
    session.setDisplayUpdatesEnabled(true) // Startup owns its one full request.
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
    session.setDisplayUpdatesEnabled(true) // Off/on coalesced before the worker runs.
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
