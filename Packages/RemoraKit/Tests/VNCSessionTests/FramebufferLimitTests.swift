import Foundation
import Metal
import RemoraCore
import Testing
import VNCSession

private final class MetalFrames: FrameSink, @unchecked Sendable {
    let desktop: MetalDesktop
    private let lock = NSLock()
    private var errors = 0
    init() throws { desktop = try MetalDesktop(device: #require(MTLCreateSystemDefaultDevice())) }
    func consume(_ frame: BorrowedFrame) {
        do { _ = try desktop.ingest(frame) }
        catch { lock.withLock { errors += 1 } }
    }
    var failures: Int { lock.withLock { errors } }
}

@Test @MainActor func vncDesktopLimitsMatchTheRealMetalRenderer() async throws {
    for (mode, width, height, supported) in [
        ("size", 16385, 1, false), ("size", 1, 16385, false),
        ("size-resize", 16385, 1, false), ("size-resize", 1, 16385, false),
        ("size", 8193, 8193, false),
        ("size", 16384, 1, true), ("size-resize", 1, 16384, true)
    ] {
        let peer = try SessionPeer(arguments: [mode, String(width), String(height)])
        defer { peer.stop() }
        let frames = try MetalFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: frames, certificateStoreURL: pins)
        defer { session.disconnect() }
        var connected = false
        var reason: DisconnectReason?
        let observer = Task { @MainActor in
            for await event in session.events {
                if case .stateChanged(.connected) = event { connected = true }
                if case .stateChanged(.disconnected(let failure)) = event { reason = failure }
            }
        }
        session.connect()
        if mode == "size-resize" {
            _ = try await peer.wait("request", count: 2)
            try peer.command("resize")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let expected = DesktopSize(width: width, height: height)
        while ContinuousClock.now < deadline && reason == nil && frames.failures == 0 && frames.desktop.size != expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        session.disconnect()
        await observer.value
        #expect(frames.failures == 0)
        if supported {
            #expect(connected)
            #expect(frames.desktop.size == expected)
            let snapshot = try frames.desktop.snapshot()
            #expect(snapshot.size == expected)
        } else {
            #expect(connected == (mode == "size-resize"))
            let detail = "The VNC desktop is \(width) × \(height) pixels, which is larger than Remora can display."
            #expect(reason == (mode == "size-resize" ? .serverEndedSession(detail) : .protocolError(detail)))
            #expect(frames.desktop.size == (mode == "size-resize" ? .init(width: 16, height: 16) : nil))
        }
        #expect(peer.events("error").isEmpty)
    }
}
