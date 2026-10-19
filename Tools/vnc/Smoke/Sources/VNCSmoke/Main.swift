import Foundation
import Darwin
import Metal
import RemoraCore
import VNCSession

struct Target: Decodable { let host: String; let port: UInt16; let username: String; let password: String }
struct SmokeFailure: Error { let message: String }
final class Sink: FrameSink, @unchecked Sendable {
    let desktop: MetalDesktop
    let lock = NSLock()
    private var frames = 0
    private var failed = false
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SmokeFailure(message: "Metal is unavailable") }
        desktop = try MetalDesktop(device: device)
    }
    func consume(_ frame: BorrowedFrame) { do { _ = try desktop.ingest(frame); lock.withLock { frames += 1 } } catch { lock.withLock { failed = true }; print("INGEST_FAILED \(error)") } }
    var count: Int { lock.withLock { frames } }
    var ingestFailed: Bool { lock.withLock { failed } }
}
@main struct Main {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor static func run() async throws {
        umask(0o077)
        let args = CommandLine.arguments
        let modes: Set<String> = ["accept", "reject", "wrong-password", "input", "prompt-cancel", "disconnect", "resize", "clipboard", "pointer", "hidden", "recording", "cursor"]
        guard args.count == 4 || args.count == 5, modes.contains(args[3]) else {
            throw SmokeFailure(message: "Usage: VNCSmoke TARGET_JSON PIN_DIRECTORY \(modes.sorted().joined(separator: "|")) [OUTPUT_PNG_OR_MOV]")
        }
        let target = try JSONDecoder().decode(Target.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let mode = args[3]
        guard mode != "recording" || args.count == 5 else { throw SmokeFailure(message: "recording requires an output MOV path") }
        let sink = try Sink()
        let config = SessionConfiguration(host: target.host, port: target.port, username: target.username,
            password: mode == "wrong-password" ? "deliberately-invalid-vnc-password" : mode == "prompt-cancel" ? nil : target.password,
            desktopSize: .init(width: 1280, height: 800))
        let session = VNCSession(configuration: config, frameSink: sink, certificateStoreURL: URL(fileURLWithPath: args[2], isDirectory: true))
        let started = ContinuousClock.now
        var timedOut = false
        var connected = false
        var trustSeen = false
        var credentialsSeen = false
        var cursorSeen = false
        var clipboardReceived = false
        var resizeRequestSent = false
        var resizeOrigin: Bool?
        var resizeCapabilityLost = false
        var resizeCapableAtCompletion = false
        var operationPassed = false
        var operationFailure: String?
        var endedReason: DisconnectReason?
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            timedOut = true
            session.disconnect()
        }
        session.connect()
        if mode == "disconnect" { Task { try? await Task.sleep(for: .milliseconds(5)); session.disconnect() } }
        for await event in session.events {
            switch event {
            case .stateChanged(let state):
                print("STATE \(state)")
                if case .disconnected(let reason) = state { endedReason = reason }
                if state == .connected, !connected {
                    connected = true
                    print("SECURITY \(session.negotiatedSecurity ?? "unknown")")
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if mode == "input", let request = session.beginAgentInput() {
                            do {
                                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                                let shift = try PhysicalKey.chord("ShiftLeft")[0]
                                let a = try PhysicalKey.chord("KeyA")[0]
                                try await request.send(.pointer(.init(x: 500, y: 75), []), deadline: deadline)
                                try await request.send(.pointer(.init(x: 500, y: 75), .left), deadline: deadline)
                                try await request.send(.pointer(.init(x: 500, y: 75), []), deadline: deadline)
                                for scalar in "Remora äöüß €".unicodeScalars { try await request.send(.unicode(scalar), deadline: deadline) }
                                try await request.send(.key(shift, down: true), deadline: deadline)
                                session.sendKey(.init(keyCode: 0x38, isDown: true)); session.releaseHumanInput()
                                try await request.send(.key(a, down: true), deadline: deadline)
                                try await request.send(.key(a, down: false), deadline: deadline)
                                try await request.send(.wheel(.init(vertical: -120, horizontal: 120)), deadline: deadline)
                                request.cancel()
                                operationPassed = await request.finish()
                                print("INPUT_RELEASE \(operationPassed)")
                            } catch { operationFailure = "Input failed: \(error)"; request.cancel(); print("INPUT_RELEASE \(await request.finish())") }
                        }
                        if mode == "resize" {
                            resizeRequestSent = true
                            session.requestResize(.init(width: 1100, height: 720), scale: 1)
                            try? await Task.sleep(for: .seconds(2))
                        }
                        if mode == "pointer" || mode == "clipboard", let request = session.beginAgentInput() {
                            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                            func click(_ y: UInt16) async throws {
                                try await request.send(.pointer(.init(x: 500, y: y), []), deadline: deadline)
                                try await request.send(.pointer(.init(x: 500, y: y), .left), deadline: deadline)
                                try await Task.sleep(for: .milliseconds(50))
                                try await request.send(.pointer(.init(x: 500, y: y), []), deadline: deadline)
                            }
                            do {
                                if mode == "pointer" {
                                    try await click(400)
                                    try await request.send(.wheel(.init(vertical: -120, horizontal: 120)), deadline: deadline)
                                } else {
                                    session.setLocalClipboard(text: "Remora UTF8 äöüß € 界")
                                    try await Task.sleep(for: .milliseconds(500))
                                    try await click(170)
                                    try await Task.sleep(for: .milliseconds(500))
                                    try await click(120)
                                    try await Task.sleep(for: .seconds(1))
                                }
                                operationPassed = await request.finish()
                                print("POINTER_RELEASE \(operationPassed)")
                            } catch { operationFailure = "Pointer failed: \(error)"; request.cancel(); print("POINTER_RELEASE \(await request.finish())") }
                        }
                        if mode == "hidden" {
                            let before = sink.count
                            session.setDisplayUpdatesEnabled(false)
                            try? await Task.sleep(for: .seconds(1))
                            let hidden = sink.count
                            session.setDisplayUpdatesEnabled(true)
                            try? await Task.sleep(for: .seconds(1))
                            print("DEMAND before=\(before) hidden=\(hidden) resumed=\(sink.count)")
                            operationPassed = sink.count > hidden
                        }
                        if mode == "recording" {
                            let capture = SessionCapture(media: AppleCaptureMedia(), destination: ScreenshotDestination())
                            capture.setSource(sink.desktop)
                            do {
                                let output = URL(fileURLWithPath: args[4])
                                try capture.startRecording(connectionName: "VNC synthetic", output: output)
                                try await Task.sleep(for: .seconds(2))
                                guard let result = await capture.stopRecording() else { throw SmokeFailure(message: "Recording returned no result") }
                                print("RECORDING \(try result.get().path)")
                                operationPassed = true
                            } catch { operationFailure = "Recording failed: \(error)" }
                        }
                        try? await Task.sleep(for: .seconds(1))
                        print("FRAMES \(sink.count) SIZE \(String(describing: sink.desktop.size)) RESIZE \(session.supportsDynamicResize)")
                        resizeCapableAtCompletion = session.supportsDynamicResize
                        if mode != "recording", args.count > 4, sink.count > 0 {
                            do {
                                let media = AppleCaptureMedia()
                                let png = try media.png(sink.desktop.snapshot())
                                let output = URL(fileURLWithPath: args[4])
                                _ = try ScreenshotDestination.reserve(at: output)
                                try png.write(to: output)
                                print("CAPTURE \(png.count) bytes")
                            } catch { operationFailure = "Capture failed: \(error)" }
                        }
                        session.disconnect()
                    }
                }
            case .trustChallenge(let challenge):
                trustSeen = true
                print("TRUST \(challenge.status) \(challenge.fingerprint)")
                challenge.responder.respond(mode == "reject" ? .reject : .trust)
            case .credentialsChallenge(let challenge):
                credentialsSeen = true
                print("CREDENTIALS \(challenge.fields)")
                if mode == "prompt-cancel" { session.disconnect() }
                else { challenge.responder.respond(.init(username: target.username, password: target.password)) }
            case .desktopSizeChanged(let size, let requested):
                print("SIZE \(size) REQUESTED \(requested)")
                if resizeRequestSent, size == .init(width: 1100, height: 720) { resizeOrigin = requested }
            case .dynamicResizeChanged(let value):
                print("RESIZE_CAPABILITY \(value)")
                if resizeRequestSent, !value { resizeCapabilityLost = true }
            case .clipboardChanged(let revision, let status):
                switch status {
                case .text(let text):
                    print("CLIPBOARD \(revision) TEXT \(text)")
                    if text == "Remora clipboard: Grüße 日本語 🐟" { clipboardReceived = true }
                default: print("CLIPBOARD \(revision) \(status)")
                }
            case .cursorChanged(let cursor):
                switch cursor {
                case .image(_, let w, let h, let hotspot):
                    cursorSeen = w > 0 && h > 0
                    print("CURSOR \(w)x\(h) HOTSPOT \(hotspot)")
                case .hidden: print("CURSOR hidden")
                case .systemDefault: print("CURSOR default")
                }
            }
        }
        watchdog.cancel()
        print("ENDED ELAPSED \(started.duration(to: .now))")
        guard !timedOut, !sink.ingestFailed, operationFailure == nil else {
            throw SmokeFailure(message: operationFailure ?? "Timed out or failed to ingest pixels")
        }
        switch mode {
        case "reject":
            guard trustSeen, !connected, endedReason == .certificateRejected else { throw SmokeFailure(message: "Expected certificate rejection before connecting; use a fresh or mismatched pin directory") }
        case "wrong-password":
            guard !connected, endedReason == .authenticationFailed else { throw SmokeFailure(message: "Expected authentication failure before connecting") }
        case "prompt-cancel":
            guard credentialsSeen, !connected, endedReason == .cancelledByUser else { throw SmokeFailure(message: "Expected credentials prompt cancellation") }
        case "disconnect":
            guard !connected, endedReason == .cancelledByUser else { throw SmokeFailure(message: "Expected connection cancellation") }
        default:
            guard connected, sink.count > 0 else { throw SmokeFailure(message: "Expected a connected desktop and pixels") }
            if ["input", "pointer", "clipboard", "hidden", "recording"].contains(mode), !operationPassed { throw SmokeFailure(message: "Operation did not finish successfully") }
            if mode == "clipboard", !clipboardReceived { throw SmokeFailure(message: "Expected synthetic remote UTF-8 clipboard text") }
            if mode == "cursor", !cursorSeen { throw SmokeFailure(message: "Expected a cursor image") }
            if mode == "resize", resizeOrigin != false || resizeCapabilityLost || !resizeCapableAtCompletion || sink.desktop.size != .init(width: 1100, height: 720) { throw SmokeFailure(message: "Expected wayvnc's asynchronous 1100x720 geometry, server-reported origin, matching frame, and retained resize capability") }
        }
        print("PASS \(mode)")
    }
}
