import Foundation
import RemoraControl
import RemoraCore

extension CommandLineController {
    func handleClipboard(_ request: ControlRequest) async throws -> ControlValue {
        guard ["clipboard.get", "clipboard.set"].contains(request.command) else { throw ControlFailure(.unknownCommand, "Unknown clipboard command.") }
        try request.validateArguments(request.command == "clipboard.set" ? ["text"] : [], sessionAllowed: true)
        let session = try resolveSession(request.session)
        let id = session.attemptID
        let text = try request.string("text", required: request.command == "clipboard.set")
        if text?.utf8.contains(0) == true { throw ControlFailure(.invalidArgument, "Clipboard text cannot contain NUL bytes.") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeout ?? 10))
        while true {
            guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced.")
            }
            if text != nil { try session.checkUserHold() }
            try promptRequired(session)
            guard session.isConnected else { throw ControlFailure(.notConnected, "The session is not connected.") }
            if text != nil { try session.checkAgentInput() }
            if let text, session.remoteClipboard.status != .notReady {
                try session.offerClipboardText(text, agent: request.agent)
                return .object(["session": .string(id.uuidString), "offered": .bool(true)])
            }
            switch session.remoteClipboard.status {
            case .received(let flavors), .offered(let flavors):
                guard let text = RemoteClipboard.plainText(in: flavors) else { throw ControlFailure(.unsupported, "The remote clipboard does not offer text.") }
                return .object(["session": .string(id.uuidString), "text": .string(text)])
            case .unavailable: throw ControlFailure(.unsupported, "The remote clipboard does not offer text.")
            case .failed: throw ControlFailure(.backendFailed, "The remote clipboard transfer failed.")
            case .notReady, .unknown, .pending: break
            }
            guard ContinuousClock.now < deadline else {
                if session.remoteClipboard.status == .notReady { throw ControlFailure(.unsupported, "The remote clipboard channel is not ready.") }
                throw ControlFailure(.timeout, "The remote clipboard did not offer text before the deadline.")
            }
            do { try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(25))), clock: .continuous) } catch {
                throw ControlFailure(.cancelled, "The command was interrupted.")
            }
        }
    }
}
