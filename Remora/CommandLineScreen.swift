import AppKit
import RemoraControl
import RemoraCore

extension CommandLineController {
    func recordingInfo(_ session: SessionViewController) -> ControlValue {
        let capture = session.capture
        let state: String
        var failure: ControlValue = .null
        switch capture.recordingState {
        case .idle: state = capture.lastRecordingResult == nil ? "idle" : "finished"
        case .recording: state = "recording"
        case .finishing: state = "finishing"
        case .failed(let error): state = "failed"; failure = .string(error.localizedDescription)
        }
        let saved = try? capture.lastRecordingResult?.get()
        return .object(["session": .string(session.attemptID.uuidString), "state": .string(state),
            "path": (capture.recordingURL ?? saved).map { .string($0.path) } ?? .null,
            "elapsed": capture.recordingState.elapsed().map(ControlValue.number) ?? .null, "error": failure])
    }

    func handleScreen(_ request: ControlRequest) async throws -> ControlReply {
        let allowed: Set<String>
        switch request.command {
        case "screenshot": allowed = ["output", "region", "maxSize"]
        case "recording.start": allowed = ["output"]
        case "recording.get", "recording.stop": allowed = []
        case "wait": allowed = ["for", "after"]
        default: throw ControlFailure(.unknownCommand, "Unknown screen command.")
        }
        try request.validateArguments(allowed, sessionAllowed: true)
        let session = try resolveSession(request.session)
        let id = session.attemptID
        let timeout = request.timeout ?? 10
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            switch request.command {
            case "screenshot":
                let output = try request.string("output")
                let region = try request.string("region").map { text -> ScreenshotRegion in
                    let values = try integers(text, separator: ",", count: 4)
                    guard values[0] >= 0, values[1] >= 0, values[2] > 0, values[3] > 0 else {
                        throw ControlFailure(.invalidArgument, "region requires X,Y,W,H with nonnegative origins and positive dimensions.")
                    }
                    return ScreenshotRegion(x: values[0], y: values[1], width: values[2], height: values[3])
                }
                let maxSize = try request.string("maxSize").map { text -> DesktopSize in
                    let values = try integers(text, separator: "x", count: 2)
                    guard values.allSatisfy({ $0 > 0 }) else { throw ControlFailure(.invalidArgument, "max-size requires positive WxH dimensions.") }
                    return DesktopSize(width: values[0], height: values[1])
                }
                session.addFrameDemand()
                defer { session.removeFrameDemand() }
                try await waitForSettledFrame(session, id: id, deadline: deadline)
                if let size = session.frameSize {
                    do { _ = try ScreenshotGeometry(desktop: size, region: region, maxSize: maxSize) }
                    catch { throw ControlFailure(.invalidArgument, error.localizedDescription) }
                }
                let baseline = session.captureFrameBaseline
                let geometryRevision = session.inputGeometryRevision
                let (png, geometry, revision) = try await session.capture.screenshot(region: region, maxSize: maxSize)
                guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                    throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced during capture.")
                }
                guard session.inputGeometryRevision == geometryRevision, geometry.desktop == session.desktopSize else {
                    throw ControlFailure(.imageExpired, "The desktop resized during capture. Take another screenshot.")
                }
                try Task.checkCancellation()
                let receipt = ScreenshotReceipt(session: id, geometry: geometry, frame: revision - baseline, geometryRevision: geometryRevision)
                let path: String?
                if output == "-" { path = nil }
                else {
                    path = try await session.capture.saveScreenshot(png, connectionName: session.connection.name,
                        output: output.map { URL(fileURLWithPath: $0) }).path
                }
                guard session.inputGeometryRevision == geometryRevision else {
                    throw ControlFailure(.imageExpired, "Control changed during capture. Take another screenshot.")
                }
                session.observedForAgent()
                screenshotReceipts.append(receipt)
                if screenshotReceipts.count > 32 { screenshotReceipts.removeFirst(screenshotReceipts.count - 32) }
                var fields: [String: ControlValue] = [
                    "image": .string(receipt.id.uuidString), "session": .string(id.uuidString),
                    "path": path.map(ControlValue.string) ?? .null, "frame": .number(Double(receipt.frame)), "stale": .bool(false),
                    "desktop": dimensions(geometry.desktop), "size": dimensions(geometry.encoded),
                    "region": .array([geometry.region.x, geometry.region.y, geometry.region.width, geometry.region.height].map { .number(Double($0)) })]
                if output == "-" { fields["byteLength"] = .number(Double(png.count)) }
                return ControlReply(.success(.object(fields)), payload: output == "-" ? png : nil)
            case "recording.start":
                switch session.capture.recordingState {
                case .recording, .finishing: throw ControlFailure(.recordingBusy, "A recording is already active or finishing.")
                default: break
                }
                let output = try request.string("output").map { URL(fileURLWithPath: $0) }
                session.addFrameDemand()
                defer { session.removeFrameDemand() }
                try await waitForSettledFrame(session, id: id, deadline: deadline)
                try session.capture.startRecording(connectionName: session.connection.name, output: output)
            case "recording.stop":
                if case .failure(let failure) = await session.stopRecording() { throw failure }
            case "wait":
                switch try request.string("for", required: true)! {
                case "frame":
                    let after: Int
                    if let value = request.arguments["after"] {
                        guard case .number(let number) = value, number >= 0, number < Double(Int.max), number.rounded() == number else {
                            throw ControlFailure(.invalidArgument, "after must be a nonnegative frame revision.")
                        }
                        after = Int(number)
                    } else { after = 0 }
                    session.addFrameDemand()
                    defer { session.removeFrameDemand() }
                    try await waitFor(session, id: id, timeout: timeout) { session.state == .connected && session.frameRevision > after }
                    return ControlReply(.success(sessionInfo(session)))
                case "recording-finished":
                    guard request.arguments["after"] == nil else { throw ControlFailure(.invalidArgument, "after applies only to frame waits.") }
                    try await waitFor(session, id: id, timeout: timeout, disconnected: true) {
                        switch session.capture.recordingState { case .recording, .finishing: false; case .idle, .failed: true }
                    }
                    if case .failure(let failure) = session.capture.lastRecordingResult { throw failure }
                default: throw ControlFailure(.invalidArgument, "Unknown screen wait condition.")
                }
            default: break
            }
            return ControlReply(.success(recordingInfo(session)))
        } catch let failure as ControlFailure where failure.code == .timeout &&
            (request.command == "screenshot" || request.command == "recording.start" || request.arguments["for"] == .string("frame")) {
            throw ControlFailure(.frameTimeout, "No fresh desktop frame arrived before the deadline.", hint: "Inspect session get and try another observation.")
        } catch let failure as CaptureFailure {
            let code: ControlFailure.Code
            switch failure {
            case .busy: code = .recordingBusy
            case .noFrame: code = .noFrame
            case .destinationExists: code = .destinationExists
            case .file: code = .ioFailed
            default: code = .captureFailed
            }
            throw ControlFailure(code, failure.localizedDescription)
        } catch is CancellationError { throw ControlFailure(.cancelled, "The command was interrupted.") }
    }

    private func integers(_ text: String, separator: Character, count: Int) throws -> [Int] {
        let components = text.split(separator: separator, omittingEmptySubsequences: false)
        let values = components.compactMap { Int($0) }
        guard values.count == count, components.count == count else { throw ControlFailure(.invalidArgument, "Invalid pixel geometry '\(text)'.") }
        return values
    }

    private func dimensions(_ size: DesktopSize) -> ControlValue { .array([.number(Double(size.width)), .number(Double(size.height))]) }
}
