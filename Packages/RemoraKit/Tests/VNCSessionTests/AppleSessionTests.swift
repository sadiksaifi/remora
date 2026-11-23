import Foundation
import RemoraCore
import Testing
import os

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
    peer.arguments = ["-u", script.path, "apple-mixed", "apple-success"]
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
    #expect(result["selected_security_id"] as? Int == 36)
    #expect(result["credentials_valid"] as? Bool == true)
    #expect(result["client_init"] as? Int == 0x81)
    #expect(result["control_mode"] as? Bool == true)
    #expect(result["subscribed_before_baseline"] as? Bool == true)
    #expect(result["subscription"] as? [Int] == [0, 1, 0, 0, 0, 16, 16])
    #expect(result["error_class"] == nil)
    #expect(connected)
    #expect(session.negotiatedSecurity == "Apple SRP (AES-128-CBC session)")
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
    _ outcome: String, offers: String = "apple-mixed", updatesEnabled: Bool = true, mode: VNCMode = .apple, password: String? = "fixture-password",
    patience: Duration = .seconds(4), actions: (@MainActor @Sendable (VNCSession, ApplePixels) async throws -> Void)? = nil,
    onClipboard: ((VNCSession, RemoteClipboard.Status) -> Void)? = nil, onDisconnect: (() -> Void)? = nil
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
            #expect(session.supportsClipboardSynchronization)
            session.requestResize(.init(width: 32, height: 16), scale: 1)
            if let actions { work = Task { try await actions(session, frames) } }
        }
        if case .clipboardChanged(_, let status) = event { onClipboard?(session, status) }
        if case .stateChanged(.disconnected(let reason)) = event {
            onDisconnect?()
            if let reason { terminals.append(reason) }
        }
    }
    try await work?.value
    // Wait off the main actor, so a long peer does not delay another test's session events.
    let report = await Task.detached {
        peer.waitUntilExit()
        return output.fileHandleForReading.readDataToEndOfFile()
    }.value
    let result = try #require(JSONSerialization.jsonObject(with: report) as? [String: Any])
    #expect(result["error_class"] == nil, "\(outcome): stage=\(result["stage"] ?? "unknown")")
    return (result, terminals, frames)
}

// The peer stops reading at the start of a 640 KiB upload. Loopback socket buffers hold about 340 KiB, so the write
// stalls. Its deadline is 10 s plus the message size at 1 Mbit/s, so the session ends about 15 s after the upload starts.
@Test(arguments: [VNCMode.apple, .standard])
@MainActor func aPeerThatStopsReadingEndsTheSessionAtTheWriteDeadline(_ mode: VNCMode) async throws {
    // Random printable ASCII keeps Apple mode's compressed upload above the buffered amount.
    let text = String(String.UnicodeScalarView((0..<640 * 1024).map { _ in Unicode.Scalar(UInt8.random(in: 0x20...0x7e)) }))
    let started = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    var elapsed: Duration?
    let (wire, terminals, _) = try await appleSession(
        mode == .apple ? "apple-write-stall" : "runtime-write-stall", offers: mode == .apple ? "apple-mixed" : "ard-only", mode: mode,
        patience: .seconds(25),
        actions: { session, pixels in
            let firstFrame = ContinuousClock.now.advanced(by: .seconds(10))
            while pixels.samples.isEmpty {
                guard ContinuousClock.now < firstFrame else {
                    Issue.record("The session showed no frame within 10 s.")
                    session.disconnect()
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            started.withLock { $0 = .now }
            session.setLocalClipboard(text: text)
        },
        onDisconnect: { elapsed = started.withLock { $0 }?.duration(to: .now) })
    #expect(terminals == [.connectionTimedOut])
    // The peer reports the message's declared payload. Its deadline is 10 s plus the whole message at 1 Mbit/s.
    // A deadline per Apple record, about 10.5 s, falls below this window.
    let declared = try #require(wire["stalled_upload_declared"] as? Int)
    let deadline = 10 + Double(declared + (mode == .apple ? 16 : 8)) / 131_072
    let duration = try #require(elapsed)
    #expect(duration >= .seconds(deadline - 0.25) && duration < .seconds(deadline + 3), "\(duration), deadline \(deadline) s")
    // The client closed its transport partway through the upload.
    #expect(wire["closed_after_stall"] as? Bool == true)
    #expect(try #require(wire["stalled_bytes"] as? Int) < declared)
}

@Test @MainActor func appleClipboardDropsAReplyThatALocalUploadReplaced() async throws {
    var statuses: [RemoteClipboard.Status] = []
    let (wire, _, _) = try await appleSession(
        "apple-clipboard-stale",
        onClipboard: { session, status in
            statuses.append(status)
            if statuses == [.unknown, .pending] { session.setLocalClipboard(text: "from viewer 🦀") }
        })
    #expect(wire["clipboard_uploads"] as? [String] == ["from viewer 🦀"])
    #expect(statuses == [.unknown, .pending, .offered([.text("from viewer 🦀")]), .pending, .text("fresh")])
}

@Test @MainActor func appleClipboardExchangesPlainTextThroughThePublicSession() async throws {
    var statuses: [RemoteClipboard.Status] = []
    let (wire, _, pixels) = try await appleSession(
        "apple-clipboard",
        onClipboard: { session, status in
            statuses.append(status)
            if status == .text("from Mac ✓\0") { session.setLocalClipboard(text: "from viewer 🦀") }
            if status == .offered([.text("from viewer 🦀")]) { session.setLocalClipboard(text: "") }
        })

    #expect(wire["pasteboard_monitoring"] as? Bool == true)
    #expect(wire["clipboard_uploads"] as? [String] == ["from viewer 🦀", ""])
    #expect(
        statuses == [
            .unknown, .pending, .text("from Mac ✓\0"), .offered([.text("from viewer 🦀")]), .offered([.text("")]), .pending, .failed, .pending, .unavailable,
            .pending, .unavailable,
        ])
    #expect(pixels.samples.count == 3)
}

private func richFlavors(_ source: String) -> [RemoteClipboard.Flavor] {
    [
        .init(.png, Data([0x89]) + Data("PNG\r\n\u{1a}\n\(source)".utf8)),
        .init(.tiff, Data("II*\0\(source)".utf8)),
        .init(.rtf, Data("{\\rtf1 \(source)}".utf8)),
        .init(.html, Data("<b>\(source)</b>".utf8)),
        .text(source),
    ]
}

@Test @MainActor func appleClipboardExchangesAllFlavorsOfOneItem() async throws {
    let incoming = richFlavors("Mac")
    let outgoing = richFlavors("viewer")
    var statuses: [RemoteClipboard.Status] = []
    let (wire, _, _) = try await appleSession(
        "apple-clipboard-rich",
        onClipboard: { session, status in
            statuses.append(status)
            if status == .received(incoming) { session.setLocalClipboard(flavors: outgoing) }
        })
    #expect(wire["clipboard_uploads"] as? [String] == ["rich"])
    #expect(statuses == [.unknown, .pending, .received(incoming), .offered(outgoing), .pending, .received(incoming.dropLast() + [.text("separate item")])])
}

@Test @MainActor func appleClipboardArchiveAtEightMiBRoundTripsAfterAnOversizedOffer() async throws {
    var received: [RemoteClipboard.Flavor] = []
    var rejected = false
    let (wire, _, _) = try await appleSession(
        "apple-clipboard-boundary",
        onClipboard: { session, status in
            switch status {
            case .received(let flavors):
                received = flavors
                guard let html = flavors.first, html.format == .html else { return }
                #expect(html.data.count == 8 * 1024 * 1024 - 20 - "public.html".utf8.count)
                session.setLocalClipboard(flavors: [.init(.html, html.data + Data([0]))])
            case .failed where !rejected:
                rejected = true
                session.setLocalClipboard(flavors: received)
            default: break
            }
        })
    #expect(rejected)
    #expect(wire["clipboard_uploads"] as? [String] == ["boundary"])
    // The fixed random bytes keep the upload above 3 MiB after compression.
    #expect(try #require(wire["clipboard_upload_compressed"] as? Int) > 3 * 1024 * 1024)
}

@Test @MainActor func appleClipboardOverTheLocalLimitIsSkippedWithoutEndingTheSession() async throws {
    var statuses: [RemoteClipboard.Status] = []
    let (_, _, pixels) = try await appleSession("apple-clipboard-limit", onClipboard: { _, status in statuses.append(status) })

    #expect(statuses.prefix(7) == [.unknown, .pending, .unavailable, .pending, .unavailable, .pending, .text("after a large image")])
    #expect(pixels.samples.count == 1)
}

@Test @MainActor func appleClipboardChangeDuringEncryptionSetupIsFetchedAfterActivation() async throws {
    var statuses: [RemoteClipboard.Status] = []
    let (wire, _, _) = try await appleSession("apple-clipboard-early", onClipboard: { _, status in statuses.append(status) })

    #expect(wire["early_clipboard_fetched"] as? Bool == true)
    // The change arrives before the session reports itself connected.
    #expect(statuses.prefix(3) == [.pending, .unknown, .text("changed during setup")])
}

@Test(arguments: ["wire-limit", "length", "malformed"])
@MainActor func appleClipboardRejectsInvalidArchivesWithoutPublishingText(_ mode: String) async throws {
    var statuses: [RemoteClipboard.Status] = []
    let (_, terminals, pixels) = try await appleSession("apple-clipboard-\(mode)", onClipboard: { _, status in statuses.append(status) })

    #expect(statuses == [.unknown, .pending])
    #expect(terminals == [.serverEndedSession("The Apple clipboard archive is invalid or exceeds the size limit.")])
    #expect(pixels.samples.count == 1)
}

@Test @MainActor func appleFullPartialAndCacheUpdatesUseSubscriptionWithoutIncrementalRequests() async throws {
    let (wire, _, pixels) = try await appleSession("apple-sequence")
    #expect(wire["selected_security_id"] as? Int == 36)
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
    let hiddenMilliseconds = baselineWhileHidden ? 1300 : 11_000
    // The peer stamps the request's arrival with the same system-wide clock, so the order holds however slowly either side starts.
    let resumed = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    // A slow runner can take seconds to start either side. The fixture's deadline for these outcomes is also 30 seconds.
    let (wire, _, pixels) = try await appleSession(outcome, updatesEnabled: false, patience: .seconds(30)) { session, frames in
        if baselineWhileHidden {
            // The hidden time starts at the baseline, so it spans a retry interval however late the baseline arrives.
            let deadline = ContinuousClock.now + .seconds(10)
            while frames.samples.isEmpty {
                try #require(ContinuousClock.now < deadline, "The baseline never arrived.")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .milliseconds(hiddenMilliseconds))
        #expect(frames.samples.count == (baselineWhileHidden ? 1 : 0))
        resumed.withLock { $0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        session.setDisplayUpdatesEnabled(true)
    }
    let retried = try #require(wire["baseline_retry_at_ns"] as? Int)
    #expect(UInt64(retried) >= (try #require(resumed.withLock { $0 })), "The full request arrived while the desktop was hidden.")
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

@Test @MainActor func appleInputReachesTheIndependentPeerInSessionRecords() async throws {
    let (wire, _, frames) = try await appleSession("apple-input") { session, frames in
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while frames.samples.count < 3, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let request = try #require(session.beginAgentInput())
        let shift = try PhysicalKey.chord("ShiftLeft")[0]
        try await request.send(.key(shift, down: true), deadline: deadline)
        session.sendKey(.init(keyCode: 56, isDown: true))
        session.sendKey(.init(keyCode: 56, isDown: false))
        session.sendKey(.init(keyCode: 58, isDown: true))
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
        keys == [
            [0xffe1, 1], [0xffe7, 1], [0xffe7, 0], [0x0100_03b1, 1], [0x0100_03b1, 0], [0xffbe, 1], [0xffbe, 0], [0xffe1, 0],
        ])
    let pointers = try #require(wire["pointers"] as? [[Int]])
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

@Test @MainActor func applePartialUpdateWithoutABaselineIsSkippedAndTheScreenRequestedInFull() async throws {
    let (wire, terminals, frames) = try await appleSession("apple-no-baseline")
    #expect(frames.samples.count == 1)
    #expect(try #require(wire["requests_after_initial"] as? Int) >= 1)
    for terminal in terminals {
        switch terminal {
        case .protocolError(let detail), .serverEndedSession(let detail): #expect(!detail.contains("could not be decoded"))
        default: break
        }
    }
}

@Test @MainActor func appleMalformedUpdatesNeverPublishAnIncompleteMessage() async throws {
    for mode in ["apple-truncated", "apple-multi-invalid", "apple-control-encryption", "apple-geometry"] {
        let (_, terminals, frames) = try await appleSession(mode)
        let count = mode == "apple-truncated" ? 0 : 1
        #expect(frames.samples.count == count, "\(mode)")
        #expect(terminals.count == 1)
        if case .serverEndedSession = terminals.first {} else { Issue.record("Expected a typed runtime end for \(mode)") }
    }
}

@Test @MainActor func appleRejectsClearPixelsWhenTheServerRefusesEncryption() async throws {
    let (_, terminals, pixels) = try await appleSession("apple-refuse")
    #expect(pixels.samples.isEmpty)
    if case .protocolError(let detail) = terminals.first {
        #expect(detail.contains("session encryption could not be established"))
    } else {
        Issue.record("Expected an encryption negotiation failure")
    }
}

@Test @MainActor func appleRejectsRecordsWithAnInvalidDigest() async throws {
    let (_, terminals, pixels) = try await appleSession("apple-invalid-digest")
    #expect(pixels.samples.isEmpty)
    if case .serverEndedSession(let detail) = terminals.first {
        #expect(detail.contains("record failed validation"))
    } else {
        Issue.record("Expected an encrypted record failure")
    }
}

@Test(arguments: ["ard-only", "apple-ard", "apple-only", "unknown-ard", "tls-ard", "none-only"])
@MainActor func appleSendsNoSelectionAndNoCredentialsWithoutTheSRPLogin(_ offers: String) async throws {
    // An offer without security type 36 is an older Mac, a Mac with SRP turned off, or a downgrade attempt.
    let (wire, terminals, frames) = try await appleSession("apple-policy-reject", offers: offers)
    #expect(wire["selector_received"] as? Bool == false)
    #expect(wire["attempts"] as? Int == 1)
    #expect(frames.samples.isEmpty)
    #expect(
        terminals == [
            .protocolError(
                "The Mac didn't offer the SRP login, which proves its identity. Apple Screen Sharing mode requires that login, which never sends the password."
            )
        ])
}

@Test(arguments: ["apple-vnc", "apple-none"])
@MainActor func appleSelectsTheSRPLoginWhateverElseIsOffered(_ offers: String) async throws {
    let (wire, _, pixels) = try await appleSession("apple-sequence", offers: offers)
    #expect(wire["selected_security_id"] as? Int == 36)
    #expect(wire["credentials_valid"] as? Bool == true)
    #expect(pixels.samples.count == 3)
}

@Test(arguments: ["proof", "result"])
@MainActor func appleEndsTheLoginWhenTheServerCannotProveItHoldsTheVerifier(_ claim: String) async throws {
    // The peer has no verifier for the account. It answers with a made-up proof, or with a bare success result.
    let (wire, terminals, pixels) = try await appleSession("apple-impersonator-\(claim)")
    // The client's proof told the peer only that its one password guess was wrong.
    #expect(wire["proof_verified"] as? Bool == false)
    // The client then closed without ClientInit, records or input.
    #expect(wire["closed_after_proof"] as? Bool == true)
    #expect(wire["attempts"] as? Int == 1)
    #expect(pixels.samples.isEmpty)
    #expect(
        terminals == [
            .protocolError("The computer that answered couldn't prove that it has this account's password on record. Someone might be impersonating the Mac.")
        ])
}

@Test(arguments: [
    "group", "generator", "public-zero", "public-modulus", "iterations-zero", "iterations-excessive", "options", "flag", "trailing",
])
@MainActor func appleSendsNoProofForUnsupportedSRPParameters(_ fault: String) async throws {
    let (wire, terminals, pixels) = try await appleSession("apple-srp-\(fault)")
    #expect(wire["closed_before_proof"] as? Bool == true)
    #expect(wire["attempts"] as? Int == 1)
    #expect(pixels.samples.isEmpty)
    if case .protocolError(let detail) = terminals.first {
        #expect(detail.contains("the SRP login"))
    } else {
        Issue.record("Expected an unsupported Apple profile for \(fault)")
    }
}

@Test @MainActor func appleRejectionAfterTwentyTwoSecondsStillReportsAuthenticationFailure() async throws {
    let (_, terminals, _) = try await appleSession("apple-slow-reject", password: "wrong-password", patience: .seconds(35))
    #expect(terminals == [.authenticationFailed])
}

@Test @MainActor func appleWrongPasswordFailsAuthenticationAtTheGenuineServer() async throws {
    let (wire, terminals, pixels) = try await appleSession("apple-sequence", password: "wrong-password")
    #expect(wire["proof_verified"] as? Bool == false)
    #expect(wire["closed_without_input"] as? Bool == true)
    #expect(pixels.samples.isEmpty)
    #expect(terminals == [.authenticationFailed])
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
    // The independent peer completes the SRP login on its first connection, reads ClientInit and sends nothing.
    // The client waits out its ten-second read deadline. Vendor/apple-mvs/README.md records the Mac that did this.
    let started = Date()
    let (wire, _, pixels) = try await appleSession(
        "apple-init-withheld", password: prompted ? nil : "fixture-password", patience: .seconds(15)
    ) { session, _ in
        // Both transports report under one attempt ID, and the retired one keeps its failure evidence.
        let attempt = session.handshakeAttemptID
        let summaries = try await localVNCLog(since: started, matching: { $0.hasPrefix("Handshake attempt=\(attempt) ") }) { $0.count >= 2 }
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
    // Prefetched cases coalesce the login's success result and a header prefix before ClientInit.
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
    let (wire, _, pixels) = try await appleSession("apple-sequence")
    #expect(wire["selected_security_id"] as? Int == 36)
    #expect(wire["credentials_valid"] as? Bool == true)
    #expect(pixels.samples.count == 3)
}
