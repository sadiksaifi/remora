import Foundation
import OSLog
import RemoraCore
import Testing

@testable import VNCSession

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
    let hello = try #require(JSONSerialization.jsonObject(with: line) as? [String: Int])
    let frames = AppleFrames()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(
        configuration: .init(
            host: "127.0.0.1", port: UInt16(try #require(hello["loopback_port"])), username: "fixture-user", password: "fixture-password",
            desktopSize: .init(width: 16, height: 16), vncMode: .apple), frameSink: frames, certificateStoreURL: pins)
    defer { session.disconnect() }
    let fallback = Task {
        try? await Task.sleep(for: .seconds(3))
        session.disconnect()
    }
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
    #expect(result["subscribed_before_baseline"] as? Bool == true)
    #expect(result["subscription"] as? [Int] == [0, 1, 0, 0, 0, 16, 16])
    #expect(result["error_class"] == nil)
    #expect(connected)
    #expect(frames.count == 1)
}

private final class ApplePixels: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[UInt8]] = []
    private var damage: [[DirtyRectangle]] = []
    private var images: [[UInt8]] = []
    func consume(_ frame: BorrowedFrame) {
        let p = frame.pixels.assumingMemoryBound(to: UInt8.self)
        lock.withLock {
            values.append([p[2], p[1], p[0]])
            damage.append(frame.dirtyRectangles)
            images.append(Array(UnsafeBufferPointer(start: p, count: frame.stride * frame.height)))
        }
    }
    var samples: [[UInt8]] { lock.withLock { values } }
    var rectangles: [[DirtyRectangle]] { lock.withLock { damage } }
    var snapshots: [[UInt8]] { lock.withLock { images } }
}

@MainActor private func appleSession(
    _ outcome: String, offers: String = "ard-only", updatesEnabled: Bool = true, mode: VNCMode = .apple, password: String? = "fixture-password",
    patience: Duration = .seconds(4), actions: (@MainActor @Sendable (VNCSession, ApplePixels) async throws -> Void)? = nil
) async throws -> ([String: Any], [DisconnectReason], ApplePixels) {
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    peer.arguments = ["-u", try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures")).path, offers, outcome]
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
    let frames = ApplePixels()
    let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: pins) }
    let session = VNCSession(
        configuration: .init(
            host: "127.0.0.1", port: UInt16(port), username: "fixture-user", password: password, desktopSize: .init(width: 16, height: 8),
            vncMode: mode), frameSink: frames, certificateStoreURL: pins)
    defer { session.disconnect() }
    let fallback = Task {
        try? await Task.sleep(for: patience)
        session.disconnect()
    }
    defer { fallback.cancel() }
    var work: Task<Void, Error>?
    var terminals: [DisconnectReason] = []
    var prompts = 0
    session.setDisplayUpdatesEnabled(updatesEnabled)
    session.connect()
    for await event in session.events {
        if case .credentialsChallenge(let challenge) = event {
            // One prompt is answered. A second prompt is declined, which ends the session.
            prompts += 1
            challenge.responder.respond(prompts == 1 ? SessionCredentials(username: "fixture-user", password: "fixture-password") : nil)
        }
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
    #expect(wire["subscribed_before_baseline"] as? Bool == true)
    #expect(wire["requests_after_initial"] as? Int == 0)
    #expect(wire["subscriptions"] as? [[Int]] == [[0, 1, 0, 0, 0, 16, 8]])
    #expect(pixels.samples == [[148, 148, 148], [151, 147, 148], [151, 147, 148]])
    #expect(
        pixels.rectangles == [
            [.init(x: 0, y: 0, width: 16, height: 8)],
            [.init(x: 0, y: 0, width: 8, height: 8)],
            [.init(x: 8, y: 0, width: 8, height: 8)],
        ])
    let gray: [UInt8] = [148, 148, 148, 255]
    let reddish: [UInt8] = [148, 147, 151, 255]
    let expected = [(gray, gray), (reddish, gray), (reddish, reddish)].map { left, right in
        Array(
            repeating: Array(repeating: left, count: 8).flatMap { $0 }
                + Array(repeating: right, count: 8).flatMap { $0 }, count: 8
        ).flatMap { $0 }
    }
    #expect(pixels.snapshots == expected)
}

@Test(arguments: ["dropped", "empty", "quant", "raw", "controls"])
@MainActor func appleRetriesFullRequestsUntilACompleteBaselineArrives(_ first: String) async throws {
    let (wire, _, pixels) = try await appleSession("apple-retry-\(first)")
    #expect(wire["subscribed_before_baseline"] as? Bool == true)
    #expect(wire["requests_after_initial"] as? Int == (first == "dropped" ? 2 : 1))
    #expect(wire["subscriptions"] as? [[Int]] == [[0, 1, 0, 0, 0, 16, 8]])
    #expect(pixels.samples.count == 3)
    #expect(Array(pixels.samples.suffix(3)) == [[148, 148, 148], [151, 147, 148], [151, 147, 148]])
}

@Test(arguments: [false, true])
@MainActor func appleBaselineRetriesPauseWhileHiddenAndResumeWithOneFullRequest(_ baselineWhileHidden: Bool) async throws {
    let outcome = baselineWhileHidden ? "apple-hidden-baseline" : "apple-retry-hidden"
    let (wire, _, pixels) = try await appleSession(outcome, updatesEnabled: false) { session, frames in
        try await Task.sleep(for: .milliseconds(1300))
        #expect(frames.samples.count == (baselineWhileHidden ? 1 : 0))
        session.setDisplayUpdatesEnabled(true)
    }
    #expect(try #require(wire["baseline_retry_ms"] as? Int) >= 1200)
    #expect(wire["requests_after_initial"] as? Int == 1)
    #expect(wire["subscriptions"] as? [[Int]] == [[0, 1, 0, 0, 0, 16, 8], [0, 1, 4_294_967_295, 0, 0, 16, 8], [0, 1, 0, 0, 0, 16, 8]])
    #expect(pixels.samples.count == 3)
}

@Test @MainActor func appleDamageUnionsAllRectanglesAndPublishesOnlyValidatedWrites() async throws {
    let (_, _, pixels) = try await appleSession("apple-damage")
    #expect(
        pixels.rectangles == [
            [.init(x: 0, y: 0, width: 16, height: 8)],
            [.init(x: 0, y: 0, width: 16, height: 8)],
            [.init(x: 0, y: 0, width: 8, height: 8)],
            [.init(x: 8, y: 0, width: 8, height: 8)],
            [.init(x: 1, y: 1, width: 12, height: 5)],
            [.init(x: 1, y: 0, width: 15, height: 8)],
        ])
    let gray: [UInt8] = [148, 148, 148, 255]
    var image = Array(repeating: gray, count: 16 * 8).flatMap { $0 }
    var expected = [image, image]
    func paint(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ bgra: [UInt8]) {
        for row in y..<(y + height) {
            for col in x..<(x + width) {
                let offset = (row * 16 + col) * 4
                image.replaceSubrange(offset..<(offset + 4), with: bgra)
            }
        }
    }
    paint(0, 0, 8, 8, [148, 147, 151, 255])
    expected.append(image)
    paint(8, 0, 8, 8, [148, 147, 151, 255])
    expected.append(image)
    paint(1, 1, 2, 2, [1, 2, 3, 255])
    paint(10, 4, 3, 2, [4, 5, 6, 255])
    expected.append(image)
    paint(1, 2, 2, 2, [7, 8, 9, 255])
    paint(8, 0, 8, 8, [148, 147, 151, 255])
    expected.append(image)
    #expect(pixels.snapshots == expected)
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
        try await Task.sleep(for: .milliseconds(200))
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
    #expect(
        keys.map { Array($0.prefix(2)) } == [
            [0xffe1, 1], [0xffe7, 1], [0xffe7, 0], [0x0100_03b1, 1], [0x0100_03b1, 0], [0xffbe, 1], [0xffbe, 0], [0xffe1, 0],
        ])
    #expect(keys.allSatisfy { $0.count == 3 })
    // Apple sends elapsed microseconds since the preceding combined input event.
    // The held key has a longer interval than the immediately following Unicode event.
    #expect((100_000...2_000_000).contains(keys[2][2]))
    #expect(keys[3][2] < keys[2][2])
    let pointers = try #require(wire["pointers"] as? [[Int]])
    #expect(wire["combined_pointers"] as? Int == pointers.count)
    #expect(pointers.contains([3, 9, 7]))
    #expect(pointers.suffix(2) == [[1, 9, 7], [0, 9, 7]])
    #expect(wire["scrolls"] as? [[Int]] == [[0, 1, 0, 65536, 0, 1, 9, 7], [-1, 0, -65536, 0, -1, 0, 9, 7]])
    #expect(frames.samples.count == 3)
}

@Test @MainActor func appleHiddenDemandDisablesSubscriptionAndResumeForcesOneFullRefresh() async throws {
    let (wire, _, _) = try await appleSession("apple-demand") { session, frames in
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while frames.samples.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        session.setDisplayUpdatesEnabled(false)
        try await Task.sleep(for: .milliseconds(50))
        let before = frames.samples.count
        session.setDisplayUpdatesEnabled(true)
        session.setDisplayUpdatesEnabled(true)
        #expect(session.awaitsRedraw)
        let redrawn = ContinuousClock.now.advanced(by: .seconds(2))
        while session.awaitsRedraw, ContinuousClock.now < redrawn { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!session.awaitsRedraw)
        #expect(frames.samples.count > before)
    }
    #expect(wire["subscriptions"] as? [[Int]] == [[0, 1, 0, 0, 0, 16, 8], [0, 1, 4_294_967_295, 0, 0, 16, 8], [0, 1, 0, 0, 0, 16, 8]])
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
    for (offers, selected) in [("tls-ard", 19), ("none-only", 1)] {
        let (wire, terminals, frames) = try await appleSession("apple-profile-reject", offers: offers)
        #expect(wire["selected_security_id"] as? Int == selected)
        #expect(wire["profile_rejected"] as? Bool == true)
        #expect(wire["attempts"] as? Int == 1)
        #expect(frames.samples.isEmpty)
        if case .protocolError(let detail) = terminals.first {
            #expect(detail.contains("ARD authentication"))
        } else {
            Issue.record("Expected unsupported Apple profile")
        }
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

@Test(arguments: [false, true])
@MainActor func appleWithheldServerInitRecoversOnceOnAFreshTransport(_ prompted: Bool) async throws {
    // The independent peer accepts ARD authentication on its first connection, reads ClientInit and sends nothing.
    // The client waits out its ten-second read deadline. Vendor/apple-mvs/README.md records the Mac that did this.
    let started = Date()
    let (wire, _, pixels) = try await appleSession(
        "apple-init-withheld", offers: "apple-mixed", password: prompted ? nil : "fixture-password", patience: .seconds(15)
    ) { session, _ in
        // Both transports report under one attempt ID, and the retired one keeps its failure evidence.
        let attempt = session.handshakeAttemptID
        let summaries = try await Task.detached {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "dev.sadiksaifi.Remora", "VNC")
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var summaries: [String] = []
            repeat {
                summaries = try store.getEntries(at: store.position(date: started), matching: predicate)
                    .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
                    .filter { $0.hasPrefix("Handshake attempt=\(attempt) ") }
                if summaries.count >= 2 { break }
                try await Task.sleep(for: .milliseconds(25))
            } while ContinuousClock.now < deadline
            return summaries
        }.value
        #expect(summaries.count == 2)
        #expect(summaries.first?.contains(" connected=0 native_error=11 phase=18 last_success=17 failure=10 ") == true)
        #expect(summaries.last?.contains(" connected=1 native_error=0 phase=22 last_success=22 failure=0 ") == true)
    }
    #expect(wire["withheld_client_init"] as? Int == 0x81)
    #expect(wire["withheld_closed_without_input"] as? Bool == true)
    #expect(wire["attempts"] as? Int == 2)
    // The second transport ran its own key exchange and carried the same credentials. A second prompt would have ended it.
    #expect(wire["fresh_exchange"] as? Bool == true)
    #expect(wire["credentials_valid"] as? Bool == true)
    #expect(wire["subscribed_before_baseline"] as? Bool == true)
    #expect(pixels.samples == [[148, 148, 148], [151, 147, 148], [151, 147, 148]])
}

@Test(arguments: ["prefetched-1", "prefetched-23", "partial", "name"])
@MainActor func appleDoesNotRetryAfterAnyServerInitPrefix(_ first: String) async throws {
    // Prefetched cases coalesce ARD success and a header prefix before ClientInit.
    // The other cases send a header prefix or a complete header/partial name after it.
    let (wire, terminals, pixels) = try await appleSession("apple-init-stalled-\(first)", patience: .seconds(15))
    #expect(wire["credentials_valid"] as? Bool == true)
    #expect(wire["client_init"] as? Int == 0x81)
    #expect(wire["closed_without_input"] as? Bool == true)
    #expect(wire["second_connection"] as? Bool == false)
    #expect(wire["attempts"] as? Int == 1)
    #expect(pixels.samples.isEmpty)
    #expect(terminals.count == 1)
    if case .protocolError = terminals.first {} else { Issue.record("Expected setup failure after a ServerInit prefix") }
}

@Test @MainActor func standardModeWithheldServerInitFailsWithoutASecondConnection() async throws {
    // The same stall outside the Apple profile stays one failed attempt. The peer waits 0.5 s for a second connection.
    let (wire, terminals, _) = try await appleSession("init-withheld-once", mode: .standard, patience: .seconds(15))
    #expect(wire["withheld_client_init"] as? Int == 1)
    #expect(wire["second_connection"] as? Bool == false)
    #expect(terminals.count == 1)
    if case .protocolError = terminals.first {} else { Issue.record("Expected the existing setup failure in standard mode") }
}

@Test @MainActor func cancellingAnAppleServerInitWaitOpensNoSecondConnection() async throws {
    // The session is cancelled two seconds in, while it waits for ServerInit.
    let (wire, terminals, _) = try await appleSession("apple-init-withheld-once", patience: .seconds(2))
    #expect(wire["withheld_client_init"] as? Int == 0x81)
    #expect(wire["second_connection"] as? Bool == false)
    #expect(terminals == [.cancelledByUser])
}

@MainActor func verifyApplePrecedesStandardSecuritySequence() async throws {
    let (wire, _, pixels) = try await appleSession("apple-sequence", offers: "apple-ard")
    #expect(wire["selected_security_id"] as? Int == 30)
    #expect(wire["credentials_valid"] as? Bool == true)
    #expect(pixels.samples.count == 3)
}
