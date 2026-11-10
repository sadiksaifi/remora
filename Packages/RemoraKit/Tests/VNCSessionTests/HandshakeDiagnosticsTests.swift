import Foundation
import OSLog
import RemoraCore
import Testing

@testable import VNCSession

private final class DiagnosticFrames: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func consume(_ frame: BorrowedFrame) { lock.withLock { frames += 1 } }
    var count: Int { lock.withLock { frames } }
}

@Test @MainActor func vncAppleSelectionAndHandshakeDiagnosticsReachTheLocalLog() async throws {
    // Independently served protocol boundaries: policy, transport EOF, local
    // crypto failure, and a fully validated ARD exchange followed by init EOF.
    for (offers, outcome, phase, lastSuccess, failure, selection, expectedOffers) in [
        ("apple-mixed", "success", 22, 22, 0, 30, "30,33,36,2,35"),
        ("unknown-ard", "expect-policy-reject", 6, 5, 2, 0, "30,250"),
        ("apple-vnc", "expect-policy-reject", 6, 5, 2, 0, "33,35,36,2"),
        ("apple-none", "expect-policy-reject", 6, 5, 2, 0, "33,35,36,1"),
        ("ard-only", "close-after-selection", 9, 6, 9, 30, "30"),
        ("ard-only", "crypto-failure", 10, 9, 5, 30, "30"),
        ("ard-only", "server-init-eof", 18, 17, 9, 30, "30"),
        ("ard-only", "success", 22, 22, 0, 30, "30"),
    ] {
        let started = Date()
        let peer = Process()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures"))
        peer.arguments = ["-u", script.path, offers, outcome]
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
        let port = UInt16(try #require(hello["loopback_port"]))
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let frames = DiagnosticFrames()
        let session = VNCSession(
            configuration: .init(
                host: "127.0.0.1", port: port, username: "fixture-user", password: "fixture-password", desktopSize: .init(width: 16, height: 16)),
            frameSink: frames, certificateStoreURL: pins)
        let fallback = Task {
            do {
                try await Task.sleep(for: .seconds(3))
                session.disconnect()
            } catch {}
        }
        defer {
            fallback.cancel()
            session.disconnect()
        }
        var connected = false
        var challenges = 0
        var reason: DisconnectReason?
        session.connect()
        for await event in session.events {
            switch event {
            case .stateChanged(.connected): connected = true
            case .stateChanged(.disconnected(let failure)): reason = failure
            case .credentialsChallenge(let challenge):
                challenges += 1
                challenge.responder.respond(nil)
            default: break
            }
        }
        #expect(connected == (outcome == "success"))
        if outcome == "success" { #expect(frames.count == 1) }
        #expect(challenges == 0)
        if outcome != "success" {
            if case .protocolError = reason {} else { Issue.record("Expected the existing protocol-error classification for \(outcome).") }
        }
        peer.waitUntilExit()
        #expect(peer.terminationStatus == 0)
        let peerResult = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        #expect(peerResult["error_class"] == nil)
        if outcome == "expect-policy-reject" { #expect(peerResult["selector_received"] as? Bool == false) }
        if outcome == "server-init-eof" || outcome == "success" { #expect(peerResult["credentials_valid"] as? Bool == true) }

        let attemptID = session.handshakeAttemptID
        // Unified-log enumeration is synchronous and can take seconds. Keep it
        // off MainActor so other public-session timing/cancellation tests run.
        let attemptMessages = try await Task.detached {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "dev.sadiksaifi.Remora", "VNC")
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var messages: [String] = []
            repeat {
                messages = try store.getEntries(at: store.position(date: started), matching: predicate)
                    .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
                    .filter { $0.contains("attempt=\(attemptID) ") }
                if !messages.isEmpty { break }
                try await Task.sleep(for: .milliseconds(25))
            } while ContinuousClock.now < deadline
            return messages
        }.value
        if outcome != "success" { #expect(!attemptMessages.contains(where: { $0.hasPrefix("Runtime failure ") })) }
        let messages = attemptMessages.filter { $0.hasPrefix("Handshake ") }
        #expect(messages.count == 1)
        guard let message = messages.first else { continue }
        print("Observed VNC diagnostic: \(message)")
        let fields = Dictionary(
            uniqueKeysWithValues: message.split(separator: " ").compactMap { token -> (String, String)? in
                let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
        #expect(fields["connected"] == (outcome == "success" ? "1" : "0"))
        #expect(Int(fields["phase"] ?? "") == phase)
        #expect(Int(fields["last_success"] ?? "") == lastSuccess)
        #expect(Int(fields["failure"] ?? "") == failure)
        #expect(Int(fields["selected"] ?? "") == selection)
        #expect(fields["server"] == "3.889")
        #expect(fields["negotiated"] == "3.8")
        #expect(fields["offered"] == expectedOffers)
        if outcome == "crypto-failure" {
            #expect(fields["ard_bits"] == "256")
            #expect(UInt64(fields["openssl"] ?? "") ?? 0 != 0)
        }
        for forbidden in ["fixture-user", "fixture-password", "synthetic-ard-peer", "synthetic fixture rejection", "127.0.0.1"] {
            #expect(!message.contains(forbidden))
        }
    }
}

@Test @MainActor func vncRuntimeFailuresReachTheLocalLogWithoutLosingTheirFirstCause() async throws {
    // Synthetic protocol faults prove diagnostic attribution, not Mac behavior.
    for (outcome, failure, stage, operation, messageType, encoding, x, callbacks) in [
        ("runtime-message", 11, 2, 0, 199, -2_147_483_649, 0, 0),
        ("runtime-encoding", 12, 6, 0, 0, 123456, 0, 0),
        ("runtime-bounds", 13, 5, 0, 0, 0, 12, 0),
        ("runtime-partial", 9, 6, 1, 0, 0, 0, 0),
        ("runtime-decoder", 14, 6, 0, 0, 7, 0, 0),
        ("runtime-success", 9, 2, 1, -1, -2_147_483_649, 0, 1),
    ] {
        let started = Date()
        let peer = Process()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures"))
        peer.arguments = ["-u", script.path, "ard-only", outcome]
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
        let port = UInt16(try #require(hello["loopback_port"]))
        let frames = DiagnosticFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(
                host: "127.0.0.1", port: port, username: "fixture-user", password: "fixture-password", desktopSize: .init(width: 16, height: 16)),
            frameSink: frames, certificateStoreURL: pins)
        let fallback = Task {
            do {
                try await Task.sleep(for: .seconds(3))
                session.disconnect()
            } catch {}
        }
        defer {
            fallback.cancel()
            session.disconnect()
        }
        var connected = false
        var reason: DisconnectReason?
        session.connect()
        for await event in session.events {
            switch event {
            case .stateChanged(.connected): connected = true
            case .stateChanged(.disconnected(let failure)): reason = failure
            default: break
            }
        }
        #expect(connected)
        #expect(frames.count == callbacks)
        if case .serverEndedSession = reason {} else { Issue.record("Runtime diagnostic must preserve the existing session-ended reason.") }
        peer.waitUntilExit()
        #expect(peer.terminationStatus == 0)
        let attemptID = session.handshakeAttemptID
        let messages = try await Task.detached {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", "dev.sadiksaifi.Remora", "VNC")
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var messages: [String] = []
            repeat {
                messages = try store.getEntries(at: store.position(date: started), matching: predicate)
                    .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
                    .filter { $0.contains("attempt=\(attemptID) ") }
                if messages.contains(where: { $0.hasPrefix("Runtime failure ") }) { break }
                try await Task.sleep(for: .milliseconds(25))
            } while ContinuousClock.now < deadline
            return messages
        }.value
        let handshakes = messages.filter { $0.hasPrefix("Handshake ") }
        #expect(handshakes.count == 1)
        #expect(handshakes.first?.contains("phase=22 last_success=22 failure=0") == true)
        let runtime = messages.filter { $0.hasPrefix("Runtime failure ") }
        #expect(runtime.count == 1)
        guard let message = runtime.first else { continue }
        print("Observed VNC runtime diagnostic: \(message)")
        let fields = Dictionary(
            uniqueKeysWithValues: message.split(separator: " ").compactMap { token -> (String, String)? in
                let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            })
        #expect(Int(fields["failure"] ?? "") == failure)
        #expect(Int(fields["stage"] ?? "") == stage)
        #expect(Int(fields["operation"] ?? "") == operation)
        #expect(Int(fields["message"] ?? "") == messageType)
        #expect(Int(fields["encoding"] ?? "") == encoding)
        #expect(Int(fields["x"] ?? "") == x)
        #expect(Int(fields["callbacks"] ?? "") == callbacks)
        #expect(fields["fb_width"] == "16" && fields["fb_height"] == "16")
        #expect(fields["cancelled"] == "0")
        if outcome != "runtime-message" && outcome != "runtime-success" {
            #expect(fields["rect_index"] == "0" && fields["rect_count"] == "1")
            #expect(fields["width"] == "16" && fields["height"] == "16")
        } else {
            #expect(fields["rect_index"] == "-1" && fields["rect_count"] == "0")
            #expect(fields["width"] == "0" && fields["height"] == "0")
        }
        for forbidden in ["fixture-user", "fixture-password", "synthetic-ard-peer", "127.0.0.1"] { #expect(!message.contains(forbidden)) }
    }
}

@Test @MainActor func vncFragmentedZRLEProgressDoesNotSpendAnElapsedTimeoutBudgetPerPacket() async throws {
    // Both buffered and direct exact-read branches must tolerate more than 100
    // readiness cycles while the complete valid payload arrives within 10 s.
    for outcome in ["fragmented-small", "fragmented-large"] {
        let peer = Process()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = try #require(Bundle.module.url(forResource: "ard_peer", withExtension: "py", subdirectory: "Fixtures"))
        peer.arguments = ["-u", script.path, "ard-only", outcome]
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
        let port = UInt16(try #require(hello["loopback_port"]))
        let frames = DiagnosticFrames()
        let pins = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pins) }
        let session = VNCSession(
            configuration: .init(
                host: "127.0.0.1", port: port, username: "fixture-user", password: "fixture-password", desktopSize: .init(width: 16, height: 16)),
            frameSink: frames, certificateStoreURL: pins)
        let fallback = Task {
            do {
                try await Task.sleep(for: .seconds(8))
                session.disconnect()
            } catch {}
        }
        defer {
            fallback.cancel()
            session.disconnect()
        }
        let started = ContinuousClock.now
        session.connect()
        var connected = false
        for await event in session.events {
            if case .stateChanged(.connected) = event { connected = true }
        }
        #expect(connected)
        #expect(frames.count == 1)
        #expect(started.duration(to: .now) < .seconds(8))
        peer.waitUntilExit()
        let result = try #require(JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])
        let bytes = try #require(result["compressed_bytes"] as? Int)
        let sent = try #require(result["sent_bytes"] as? Int)
        let deliveryMS = try #require(result["delivery_ms"] as? Int)
        print("Fragmented ZRLE outcome=\(outcome) sent_bytes=\(sent) required_bytes=\(bytes) delivery_ms=\(deliveryMS) callbacks=\(frames.count)")
        #expect(peer.terminationStatus == 0)
        #expect(result["error_class"] == nil)
        #expect(sent == bytes)
        #expect(deliveryMS < 8_000)
        #expect(outcome == "fragmented-large" ? bytes > 8192 : bytes <= 8192)
    }
}
