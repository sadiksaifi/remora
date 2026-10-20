import Foundation
import RemoraCore
import Testing
import VNCSession

@Test @MainActor func vncClipboardRemovesOnlyTheExtendedTextTerminator() async throws {
    let peer = try SessionPeer(arguments: ["clipboard"])
    defer { peer.stop() }
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: MarkerFrames(), certificateStoreURL: pins)
    defer { session.disconnect() }
    let fallback = Task { do { try await Task.sleep(for: .seconds(3)); session.disconnect() } catch {} }
    defer { fallback.cancel() }
    session.connect()
    _ = try await peer.wait("request")
    try peer.command("clipboard")
    var texts: [String] = []
    for await event in session.events {
        if case .clipboardChanged(_, .text(let text)) = event {
            texts.append(text)
            if texts.count == 4 { break }
        }
    }
    #expect(texts == ["hello", "", "hé\0€", "é\0B\0"])
    #expect(peer.events("error").isEmpty)
}
