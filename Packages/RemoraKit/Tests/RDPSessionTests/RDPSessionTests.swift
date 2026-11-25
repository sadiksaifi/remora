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
        do {
            desktop = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice()))
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
            // The server starts last, so a failure above leaves no thread or socket behind.
            server = try #require(rm_test_rdp_server_start(certificate, key))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        session = Self.session(port: rm_test_rdp_server_port(server), desktop: desktop, directory: directory)
    }

    static func session(port: UInt16, desktop: MetalDesktop, directory: URL) -> RDPSession {
        RDPSession(
            configuration: .init(
                host: "127.0.0.1", port: port, username: "synthetic", password: "test-only",
                desktopSize: .init(width: 320, height: 240), allowsDynamicResize: false),
            frameSink: DesktopSink(desktop: desktop), configurationDirectory: directory.appendingPathComponent("freerdp"),
            failureDiagnosis: .init(inspect: { _, _, _ in .unconfirmed }))
    }

    /// Receives every state the session reports during `run`, as an open tab does.
    var onState: ((SessionState) -> Void)?

    var refreshes: UInt32 { rm_test_rdp_server_refreshes(server) }

    /// Connects, trusts the test identity, runs `connected` once the server has activated the connection, and
    /// returns the terminal reason after the session ends. `connected` must end the session.
    func run(_ connected: @escaping @MainActor () async throws -> Void) async throws -> DisconnectReason? {
        let session = session
        let events = Task { () -> (reason: DisconnectReason?, work: Task<Void, Error>?) in
            var work: Task<Void, Error>?
            var reason: DisconnectReason?
            for await event in session.events {
                if case .stateChanged(let state) = event { self.onState?(state) }
                switch event {
                case .trustChallenge(let challenge): challenge.responder.respond(.trust)
                case .stateChanged(.connected):
                    work = Task {
                        do {
                            // The client can finish connecting just before the server's activation callback returns.
                            try #require(try await eventually(within: .seconds(5)) { rm_test_rdp_server_activated(self.server) })
                            try await connected()
                        } catch {
                            session.disconnect()
                            throw error
                        }
                    }
                case .stateChanged(.disconnected(let terminal)): reason = terminal
                default: break
                }
            }
            return (reason, work)
        }
        // Cancelling the wait ends it even if the session never finishes its events.
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            events.cancel()
        }
        session.connect()
        let outcome = await events.value
        deadline.cancel()
        let timedOut = events.isCancelled
        if timedOut { outcome.work?.cancel() }
        // The work must finish before the caller stops the server it reads.
        let finished = await outcome.work?.result
        try #require(!timedOut, "The session was still open after 20 seconds.")
        try #require(finished, "The session never connected.").get()
        return outcome.reason
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
    let reason = try await connection.run {
        // The client sends no Refresh Rect of its own, so the only one must come from the loss.
        try #require(connection.refreshes == 0)
        try connection.loseFramebuffer()
        _ = try await eventually(within: .seconds(5)) { connection.refreshes > 0 }
        connection.session.disconnect()
    }
    #expect(reason == .cancelledByUser)
    // The server has read everything the client sent once it has ended.
    let ended = try await eventually(within: .seconds(5)) { rm_test_rdp_server_ended(connection.server) }
    #expect(ended)
    #expect(connection.refreshes == 1)
    #expect(rm_test_rdp_server_whole_refreshes(connection.server) == 1)
    #expect(connection.desktop.losses == 1)
}

/// The session removes its loss observer before it reports the end. A later loss sends nothing and does not crash.
@Test @MainActor func aGPULossAfterTheSessionEndsSendsNothing() async throws {
    let connection = try Connection()
    defer { connection.close() }
    var observedWhileConnected = 0
    let reason = try await connection.run {
        observedWhileConnected = connection.desktop.lossObserverCount
        connection.session.disconnect()
    }
    #expect(reason == .cancelledByUser)
    #expect(observedWhileConnected == 1)
    #expect(connection.desktop.lossObserverCount == 0)
    let ended = try await eventually(within: .seconds(5)) { rm_test_rdp_server_ended(connection.server) }
    #expect(ended)
    let before = connection.refreshes
    try connection.loseFramebuffer()
    try await Task.sleep(for: .milliseconds(300))
    #expect(connection.refreshes == before)
    #expect(connection.desktop.losses == 1)
}

/// The Connections list shows when a connection's session last connected, so a session sets that date only when
/// it reaches the connected state. An attempt that the host refuses leaves the earlier date, or no date, in place.
@Test @MainActor func onlyASessionThatConnectsSetsTheLastConnectedDate() async throws {
    let connection = try Connection()
    defer { connection.close() }
    let store = try ConnectionStore(fileURL: connection.directory.appendingPathComponent("connections.json"))
    let saved = RemoraCore.Connection(name: "Test", host: "127.0.0.1", username: "synthetic")
    try store.add(saved)
    func lastConnected() -> Date? { store.connections.first?.lastConnected }

    // Nothing listens on this Mac's TCP port 1, so it refuses every connection.
    let port: UInt16 = 1

    /// One attempt at the refusing port. Every state it reports goes to the store.
    func refusedAttempt() async throws -> [SessionState] {
        let session = Connection.session(port: port, desktop: connection.desktop, directory: connection.directory)
        // An attempt that hangs ends as cancelled, which fails the caller's expectation.
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            session.disconnect()
        }
        defer { deadline.cancel() }
        session.connect()
        var states: [SessionState] = []
        for await event in session.events {
            guard case .stateChanged(let state) = event else { continue }
            states.append(state)
            try store.sessionChanged(to: state, id: saved.id)
        }
        return states
    }

    #expect(try await refusedAttempt() == [.connecting, .disconnected(.connectionRefused)])
    #expect(lastConnected() == nil)

    let before = Date()
    var saveFailure: (any Error)?
    connection.onState = { state in
        do { try store.sessionChanged(to: state, id: saved.id) } catch { saveFailure = error }
    }
    #expect(try await connection.run { connection.session.disconnect() } == .cancelledByUser)
    #expect(saveFailure == nil)
    let connectedAt = try #require(lastConnected())
    #expect(connectedAt >= before)

    #expect(try await refusedAttempt() == [.connecting, .disconnected(.connectionRefused)])
    #expect(lastConnected() == connectedAt)
}
