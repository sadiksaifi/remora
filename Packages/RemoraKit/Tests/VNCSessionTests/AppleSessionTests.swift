import Foundation
import RemoraCore
import Testing
import VNCSession

private final class AppleFrames: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func consume(_ frame: BorrowedFrame) { lock.withLock { frames += 1 } }
    var count: Int { lock.withLock { frames } }
}

@Test @MainActor func appleModeRequiresTheExplicit889DialectThroughThePublicSession() async throws {
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures"))
    peer.arguments = ["-u", script.path, "ard-only", "apple-success"]
    let output = Pipe(); peer.standardOutput = output
    try peer.run()
    defer { if peer.isRunning { peer.terminate(); peer.waitUntilExit() } }
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
    let hello = try #require(JSONSerialization.jsonObject(with: line) as? [String: Int])
    let frames = AppleFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: UInt16(try #require(hello["loopback_port"])), username: "fixture-user", password: "fixture-password", desktopSize: .init(width: 16, height: 16), vncMode: .apple), frameSink: frames, certificateStoreURL: pins)
    defer { session.disconnect() }
    let fallback = Task { try? await Task.sleep(for: .seconds(3)); session.disconnect() }
    defer { fallback.cancel() }
    var connected = false
    session.connect()
    for await event in session.events {
        if case .stateChanged(.connected) = event { connected = true }
    }
    peer.waitUntilExit()
    let result = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    #expect(result["version_889"] as? Bool == true)
    #expect(result["credentials_valid"] as? Bool == true)
    #expect(result["client_init"] as? Int == 0x81)
    #expect(result["control_mode"] as? Bool == true)
    #expect(result["error_class"] == nil)
    #expect(connected)
    #expect(frames.count == 1)
}

private final class ApplePixels: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[UInt8]] = []
    func consume(_ frame: BorrowedFrame) {
        let p = frame.pixels.assumingMemoryBound(to: UInt8.self)
        lock.withLock { values.append([p[2], p[1], p[0]]) }
    }
    var samples: [[UInt8]] { lock.withLock { values } }
}

@MainActor private func appleSession(_ outcome: String, offers: String = "ard-only", actions: (@MainActor @Sendable (VNCSession, ApplePixels) async throws -> Void)? = nil) async throws -> ([String: Any], [DisconnectReason], ApplePixels) {
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    peer.arguments = ["-u", try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures")).path, offers, outcome]
    let output = Pipe(); peer.standardOutput = output
    try peer.run()
    defer { if peer.isRunning { peer.terminate(); peer.waitUntilExit() } }
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
    let port = try #require((JSONSerialization.jsonObject(with: line) as? [String: Int])?["loopback_port"])
    let frames = ApplePixels()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: UInt16(port), username: "fixture-user", password: "fixture-password", desktopSize: .init(width: 16, height: 8), vncMode: .apple), frameSink: frames, certificateStoreURL: pins)
    defer { session.disconnect() }
    let fallback = Task { try? await Task.sleep(for: .seconds(4)); session.disconnect() }
    defer { fallback.cancel() }
    var work: Task<Void, Error>?
    var terminals: [DisconnectReason] = []
    session.connect()
    for await event in session.events {
        if case .stateChanged(.connected) = event {
            #expect(!session.supportsDynamicResize)
            #expect(!session.supportsClipboardSynchronization)
            session.requestResize(.init(width: 32, height: 16), scale: 1)
            session.setLocalClipboard(text: "not sent in Apple mode")
            if let actions { work = Task { try await actions(session, frames) } }
        }
        if case .stateChanged(.disconnected(let reason)) = event, let reason { terminals.append(reason) }
    }
    try await work?.value
    peer.waitUntilExit()
    let result = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
    #expect(result["error_class"] == nil, "\(outcome): stage=\(result["stage"] ?? "unknown")")
    return (result, terminals, frames)
}

@Test @MainActor func appleFullPartialAndCacheUpdatesUseSubscriptionWithoutIncrementalRequests() async throws {
    let (wire, _, pixels) = try await appleSession("apple-sequence", offers: "apple-mixed")
    #expect(wire["selected_security_id"] as? Int == 30)
    #expect(wire["requests_after_initial"] as? Int == 0)
    #expect(wire["subscriptions"] as? [[Int]] == [[0,1,0,0,0,16,8]])
    #expect(pixels.samples == [[148,148,148], [151,147,148], [151,147,148]])
}

@Test @MainActor func appleKeyEncryptionAndSourceOwnershipReachTheIndependentPeer() async throws {
    let (wire, _, frames) = try await appleSession("apple-input") { session, frames in
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while frames.samples.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let request = try #require(session.beginAgentInput())
        let shift = try PhysicalKey.chord("ShiftLeft")[0]
        try await request.send(.key(shift, down: true), deadline: deadline)
        session.sendKey(.init(keyCode: 56, isDown: true))
        session.sendKey(.init(keyCode: 56, isDown: false))
        session.sendKey(.init(keyCode: 58, isDown: true))
        try await Task.sleep(for: .milliseconds(40))
        session.sendKey(.init(keyCode: 58, isDown: false))
        try await request.send(.unicode("α"), deadline: deadline)
        try await request.send(.pointer(.init(x: 3, y: 4), .left), deadline: deadline)
        session.sendPointer(position: .init(x: 5, y: 6), buttons: .right)
        session.sendWheel(.init(vertical: 120, horizontal: 120), at: .init(x: 9, y: 7))
        session.sendKey(.init(keyCode: 122, isDown: true))
        session.sendKey(.init(keyCode: 122, isDown: false))
        session.releaseHumanInput()
        request.cancel()
        #expect(await request.finish())
    }
    let keys = try #require(wire["keys"] as? [[Int]])
    #expect(keys.map { Array($0.prefix(2)) } == [[0xffe1,1],[0xffe7,1],[0xffe7,0],[0x010003b1,1],[0x010003b1,0],[0xffbe,1],[0xffbe,0],[0xffe1,0]])
    #expect(keys.allSatisfy { $0.count == 3 && $0[2] > 0 })
    let microseconds = (keys[2][2] - keys[1][2] + 4_294_967_296) % 4_294_967_296
    #expect((20_000...2_000_000).contains(microseconds))
    let pointers = try #require(wire["pointers"] as? [[Int]])
    #expect(pointers.contains([3,9,7]))
    #expect(pointers.suffix(2) == [[1,9,7],[0,9,7]])
    #expect(wire["scrolls"] as? [[Int]] == [[0,1,0,65536,0,1,9,7],[-1,0,-65536,0,-1,0,9,7]])
    #expect(frames.samples.count == 3)
}

@Test @MainActor func appleHiddenDemandDisablesSubscriptionAndResumeForcesOneFullRefresh() async throws {
    let (wire, _, _) = try await appleSession("apple-demand") { session, frames in
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while frames.samples.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        session.setDisplayUpdatesEnabled(false)
        try await Task.sleep(for: .milliseconds(50))
        session.setDisplayUpdatesEnabled(true)
        session.setDisplayUpdatesEnabled(true)
    }
    #expect(wire["subscriptions"] as? [[Int]] == [[0,1,0,0,0,16,8],[0,0,0,0,0,16,8],[0,1,0,0,0,16,8]])
    #expect(wire["requests_after_initial"] as? Int == 1)
}

@Test @MainActor func appleMalformedUpdatesNeverPublishAnIncompleteMessage() async throws {
    for mode in ["apple-no-baseline", "apple-truncated", "apple-bad-cache", "apple-multi-invalid", "apple-control-encryption", "apple-geometry"] {
        let (_, terminals, frames) = try await appleSession(mode)
        let count = ["apple-no-baseline", "apple-truncated"].contains(mode) ? 0 : 1
        #expect(frames.samples.count == count, "\(mode)")
        #expect(terminals.count == 1)
        if case .serverEndedSession = terminals.first {} else { Issue.record("Expected a typed runtime end for \(mode)") }
    }
}

@Test @MainActor func appleSecuritySelectionDoesNotRetryOrUseAProfileWithoutItsARDKey() async throws {
    for (offers, selected) in [("tls-ard",19),("none-only",1)] {
        let (wire, terminals, frames) = try await appleSession("apple-profile-reject", offers: offers)
        #expect(wire["selected_security_id"] as? Int == selected)
        #expect(wire["profile_rejected"] as? Bool == true)
        #expect(wire["attempts"] as? Int == 1)
        #expect(frames.samples.isEmpty)
        if case .protocolError(let detail) = terminals.first { #expect(detail.contains("ARD authentication")) }
        else { Issue.record("Expected unsupported Apple profile") }
    }
    for offers in ["apple-only", "unknown-ard", "apple-none"] {
        let (wire, terminals, frames) = try await appleSession("apple-policy-reject", offers: offers)
        #expect(wire["selector_received"] as? Bool == false)
        #expect(frames.samples.isEmpty)
        if case .protocolError = terminals.first {} else { Issue.record("Expected policy rejection") }
    }
}

@Test @MainActor func appleUnsupportedInitializationAndFailedAuthenticationNeverAdmitInput() async throws {
    for mode in ["apple-wrong-banner", "apple-no-extension", "apple-session-select", "apple-reject"] {
        let (wire, terminals, pixels) = try await appleSession(mode)
        #expect(pixels.samples.isEmpty)
        if mode == "apple-reject" {
            #expect(wire["closed_without_input"] as? Bool == true)
            #expect(terminals == [.authenticationFailed])
        } else {
            if case .protocolError = terminals.first {} else { Issue.record("Expected unsupported profile for \(mode)") }
        }
    }
}

@MainActor func verifyApplePrecedesStandardSecuritySequence() async throws {
    let (wire, _, pixels) = try await appleSession("apple-sequence", offers: "apple-ard")
    #expect(wire["selected_security_id"] as? Int == 30)
    #expect(wire["credentials_valid"] as? Bool == true)
    #expect(pixels.samples.count == 3)
}
