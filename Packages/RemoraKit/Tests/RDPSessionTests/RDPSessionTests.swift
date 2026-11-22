import CFreeRDPTestServer
import Foundation
import Metal
import RDPSession
import Testing

@testable import RemoraCore

/// The session draws into this framebuffer. The server sends no pictures, so the test fills it itself.
private final class DesktopSink: FrameSink, @unchecked Sendable {
    let desktop: MetalDesktop
    init(desktop: MetalDesktop) { self.desktop = desktop }
    func consume(_ frame: BorrowedFrame) { _ = try? desktop.ingest(frame) }
    var metalDesktop: MetalDesktop? { desktop }
}

/// A connection to the in-process RDP server, with a disposable TLS identity and FreeRDP folder.
@MainActor private final class Connection {
    let directory: URL
    let server: OpaquePointer
    let desktop: MetalDesktop
    let session: RDPSession

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let certificate = directory.appendingPathComponent("certificate.pem").path
        let key = directory.appendingPathComponent("key.pem").path
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "1", "-subj", "/CN=localhost",
            "-keyout", key, "-out", certificate,
        ]
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        try #require(openssl.terminationStatus == 0)
        server = try #require(rm_test_rdp_server_start(certificate, key))
        desktop = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
        session = RDPSession(
            configuration: .init(
                host: "127.0.0.1", port: rm_test_rdp_server_port(server), username: "synthetic", password: "test-only",
                desktopSize: .init(width: 320, height: 240), allowsDynamicResize: false),
            frameSink: DesktopSink(desktop: desktop), configurationDirectory: directory.appendingPathComponent("freerdp"),
            failureDiagnosis: .init(inspect: { _, _, _ in .unconfirmed }))
    }

    var refreshes: UInt32 { rm_test_rdp_server_refreshes(server) }

    /// Connects, trusts the test identity, runs `connected`, and returns the terminal reason after the session ends.
    func run(_ connected: @escaping @MainActor () async throws -> Void) async throws -> DisconnectReason? {
        let fallback = Task {
            try? await Task.sleep(for: .seconds(20))
            session.disconnect()
        }
        defer { fallback.cancel() }
        var work: Task<Void, Error>?
        var reason: DisconnectReason?
        session.connect()
        for await event in session.events {
            switch event {
            case .trustChallenge(let challenge): challenge.responder.respond(.trust)
            case .stateChanged(.connected): work = Task { try await connected() }
            case .stateChanged(.disconnected(let terminal)): reason = terminal
            default: break
            }
        }
        try await work?.value
        return reason
    }

    /// A GPU error as the command buffer's completion reports it. The framebuffer needs a frame first.
    func loseFramebuffer() throws {
        let pixels = [UInt8](repeating: 0x40, count: 320 * 240 * 4)
        _ = try pixels.withUnsafeBytes {
            try desktop.ingest(
                BorrowedFrame(
                    pixels: $0.baseAddress!, width: 320, height: 240, stride: 1280, dirtyRectangles: [.init(x: 0, y: 0, width: 320, height: 240)]))
        }
        var drawn: (any MTLTexture)?
        _ = try desktop.submit { texture, _ in drawn = texture }
        desktop.discardFramebuffer(drawnInto: try #require(drawn))
    }

    func close() {
        session.disconnect()
        rm_test_rdp_server_stop(server)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private func eventually(within limit: Duration, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A frame drawn just before a GPU loss may be the last one for a while. The session asks the server for a redraw
/// at once, with no later frame to notice the loss.
@Test @MainActor func aGPULossOnAConnectedSessionAsksTheServerForARedraw() async throws {
    let connection = try Connection()
    defer { connection.close() }
    var before: UInt32 = 0
    var after: UInt32 = 0
    let reason = try await connection.run {
        // The client can finish connecting just before the server's activation callback returns.
        let activated = try await eventually(within: .seconds(5)) { rm_test_rdp_server_activated(connection.server) }
        #expect(activated)
        // Let any request the connection itself sends arrive first.
        try await Task.sleep(for: .milliseconds(300))
        before = connection.refreshes
        try connection.loseFramebuffer()
        _ = try await eventually(within: .seconds(5)) { connection.refreshes > before }
        after = connection.refreshes
        connection.session.disconnect()
    }
    #expect(after == before + 1)
    #expect(connection.desktop.losses == 1)
    #expect(reason == .cancelledByUser)
}

/// The session removes its loss observer when it ends. A later loss sends nothing and does not crash.
@Test @MainActor func aGPULossAfterTheSessionEndsSendsNothing() async throws {
    let connection = try Connection()
    defer { connection.close() }
    let reason = try await connection.run { connection.session.disconnect() }
    #expect(reason == .cancelledByUser)
    let ended = try await eventually(within: .seconds(5)) { rm_test_rdp_server_ended(connection.server) }
    #expect(ended)
    let before = connection.refreshes
    try connection.loseFramebuffer()
    try await Task.sleep(for: .milliseconds(300))
    #expect(connection.refreshes == before)
    #expect(connection.desktop.losses == 1)
}
