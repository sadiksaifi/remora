import Foundation
import RemoraCore
import Testing
import VNCSession

private final class SelectedFrames: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(DesktopSize, Data)] = []
    func consume(_ frame: BorrowedFrame) {
        lock.withLock {
            stored.append((.init(width: frame.width, height: frame.height), Data(bytes: frame.pixels, count: frame.stride * frame.height)))
        }
    }
    var frames: [(DesktopSize, Data)] { lock.withLock { stored } }
}

@Test(arguments: [VNCMode.apple, .standard], [false, true])
@MainActor func displaySelectionFencesPicturesInputAndSameSizeSwitches(mode: VNCMode, timeout: Bool) async throws {
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    peer.arguments = [
        "-u", try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures")).path,
        "ard-only", (mode == .apple ? "apple-" : "standard-") + (timeout ? "display-timeout" : "displays"),
    ]
    let output = Pipe()
    peer.standardOutput = output
    try peer.run()
    defer {
        if peer.isRunning {
            peer.terminate()
            peer.waitUntilExit()
        }
    }
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
    let port = try #require((JSONSerialization.jsonObject(with: line) as? [String: Int])?["loopback_port"])
    let frames = SelectedFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(
        configuration: .init(
            host: "127.0.0.1", port: UInt16(port), username: "fixture-user", password: "fixture-password",
            desktopSize: .init(width: 16, height: 8), vncMode: mode), frameSink: frames, certificateStoreURL: pins)
    let deadline = Task {
        try? await Task.sleep(for: .seconds(timeout ? 15 : 5))
        session.disconnect()
    }
    defer {
        deadline.cancel()
        session.disconnect()
    }
    var ready: [UInt32] = []
    var sizes: [DesktopSize] = []
    session.connect()
    for await event in session.events {
        switch event {
        case .desktopSizeChanged(let size, _): sizes.append(size)
        case .displaySelectionFailed(let id, let reason):
            #expect(timeout && id == 7 && reason == .timedOut)
            #expect(frames.frames.count == 1)
            #expect(!session.displays.isReady)
            try session.selectDisplay(42).get()
        case .displaysChanged(let snapshot):
            if !snapshot.isReady {
                continue
            }
            let selected = try #require(snapshot.selectedID)
            ready.append(selected)
            #expect(frames.frames.count >= ready.count)
            if ready.count == 1 {
                #expect(snapshot.displays.map(\.id) == [7, 42])
                #expect(snapshot.displays.first(where: \.isMain)?.id == 42)
                #expect(selected == 42)
                let request = try #require(session.beginAgentInput())
                try await request.send(.key(try PhysicalKey.chord("KeyA")[0], down: true), deadline: .now.advanced(by: .seconds(1)))
                try await request.send(.pointer(.init(x: 3, y: 4), .left), deadline: .now.advanced(by: .seconds(1)))
                try session.selectDisplay(7).get()
                #expect(!session.displays.isReady)
                #expect(session.displays.selectedID == nil)
                #expect(session.displays.pendingID == 7)
                #expect(throws: DisplaySelectionFailure.busy) { try session.selectDisplay(42).get() }
                #expect(throws: DisplaySelectionFailure.unavailable) { try session.selectDisplay(999).get() }
                #expect(session.beginAgentInput() == nil)
                session.sendPointer(position: .init(x: 99, y: 99), buttons: .left)
                session.sendKey(.init(keyCode: 0, isDown: true))
            }
        default: break
        }
    }
    peer.waitUntilExit()
    let report = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    #expect(report["error_class"] == nil, "\(report)")
    #expect(ready == (timeout ? [42, 42] : [42, 7, 42]))
    #expect(sizes == Array(repeating: DesktopSize(width: 16, height: 8), count: timeout ? 2 : 3))
    #expect(report["display_selections"] as? [Int] == [42, 7, 42])
    #expect(report["inputs_before_second_selection"] as? Int == 4)
    #expect((report["display_inputs"] as? [[Int]])?.count == 4)
    for (index, frame) in frames.frames.enumerated() {
        #expect(frame.0 == .init(width: 16, height: 8))
        let pixel: [UInt8] = index == 0 ? [1, 2, 3, 255] : index == 1 && !timeout ? [4, 5, 6, 255] : [7, 8, 9, 255]
        #expect(frame.1 == Data(Array(repeating: pixel, count: 16 * 8).flatMap { $0 }))
    }
}
