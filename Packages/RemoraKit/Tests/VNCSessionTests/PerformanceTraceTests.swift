import Foundation
import OSLog
import os
import RemoraCore
import Testing
@testable import VNCSession

/// Public protocol fixture used by the external xctrace verifier. OSLogStore
/// does not retain DynamicTracing signposts on this SDK, even during capture.
@Test @MainActor func vncPerformanceTraceFixture() async throws {
    let attaching = ProcessInfo.processInfo.environment["REMORA_TEST_TRACE_ATTACH"] == "1"
    let tracing = OSLog(subsystem: "dev.sadiksaifi.Remora", category: "DynamicTracing")
    if attaching { #expect(!tracing.signpostsEnabled) }
    let peer = try SessionPeer(arguments: ["perf"])
    defer { peer.stop() }
    let frames = MarkerFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 32, height: 16)), frameSink: frames, certificateStoreURL: pins)
    defer { session.disconnect() }
    session.connect()
    _ = try await peer.wait("request", count: 3)
    if attaching {
        // Test-driver stdin is released only after xctrace's actual start
        // notification. Category enablement alone can precede collection.
        try FileHandle.standardOutput.write(contentsOf: Data("VNC_TRACE_ATTACH_PID=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        #expect(try FileHandle.standardInput.read(upToCount: 1) == Data([10]))
        #expect(tracing.signpostsEnabled)
        try FileHandle.standardOutput.write(contentsOf: Data("VNC_TRACE_ATTACHED=1\n".utf8))
    }
    try peer.command("perf")
    _ = try await peer.wait("body_started")
    let agent = try #require(session.beginAgentInput())
    try await agent.send(.key(try PhysicalKey.chord("KeyA")[0], down: true), deadline: .now.advanced(by: .seconds(2)))
    #expect(await agent.finish())
    let key = try await peer.wait("key", count: 2)
    let body = try await peer.wait("body_done")
    #expect(try #require(key["ms"] as? Int) < #require(body["ms"] as? Int)-200)
    #expect(peer.events("pointer").count == 1)
    var terminal = false
    for await event in session.events {
        if case .stateChanged(.disconnected) = event { terminal = true; break }
    }
    #expect(terminal)
    #expect(frames.values.count == 2)
    #expect(peer.events("error").isEmpty)
    let expected = try await peer.wait("expected")
    let fields = ["first", "second", "logical"].map { "\($0)=\(expected[$0] as? Int ?? -1)" }.joined(separator: " ")
    try FileHandle.standardOutput.write(contentsOf: Data("VNC_TRACE_EXPECTED \(fields)\n".utf8))
}
