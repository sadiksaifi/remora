import CFreeRDPBridge
import Foundation
import RemoraCore

/// One admitted request. Call finish before admitting its successor. At most one
/// event is queued by send, so text and drags cannot flood the session queue.
final class RDPAgentInputRequest: AgentInputRequest {
    private let session: RDPSession
    private let id: UInt64

    init(session: RDPSession, id: UInt64) {
        self.session = session
        self.id = id
    }

    public func cancel() {
        session.agentHandle { rm_rdp_agent_cancel($0, id) }
    }

    public func send(_ event: AgentInputEvent, deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        var wire = RMRDPAgentEvent()
        switch event {
        case .key(let key, let down):
            wire.kind = RMRDP_AGENT_SCAN
            wire.scancode = key.scancode
            wire.down = down
        case .pointer(let point, let buttons):
            wire.kind = RMRDP_AGENT_POINTER
            wire.x = point.x
            wire.y = point.y
            wire.buttons = buttons.rawValue
        case .wheel(let wheel):
            wire.kind = RMRDP_AGENT_WHEEL
            wire.vertical = wheel.vertical
            wire.horizontal = wheel.horizontal
        case .unicode(let scalar):
            wire.kind = RMRDP_AGENT_UNICODE
            let units = Array(String(scalar).utf16)
            wire.units = UInt8(units.count)
            wire.utf16 = (units[0], units.count == 2 ? units[1] : 0)
        case .pause: wire.kind = RMRDP_AGENT_PAUSE
        }
        guard let sequence = session.agentHandle({ rm_rdp_agent_send($0, id, wire) }) else { throw AgentInputFailure.sessionEnded }
        guard sequence != 0 else { throw AgentInputFailure.submissionFailed }
        while true {
            guard ContinuousClock.now < deadline else { throw AgentInputFailure.timedOut }
            guard let status = session.agentHandle({ rm_rdp_agent_status($0, id, sequence, false) }) else { throw AgentInputFailure.sessionEnded }
            switch status {
            case 1:
                let feedback: SessionInputFeedback?
                switch event {
                case .key(let key, let down): feedback = .key(scancode: key.scancode, down: down)
                case .pointer(let point, let buttons): feedback = .pointer(point, buttons)
                case .unicode(let scalar): feedback = .text(String(scalar))
                case .pause: feedback = .key(scancode: 0x146, down: true)
                case .wheel: feedback = nil
                }
                if let feedback { session.agentHandle { _ in session.inputFeedback(.agent, feedback) } }
                return
            case -1: throw AgentInputFailure.cancelled
            case -2: throw AgentInputFailure.submissionFailed
            default: try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// Cleanup outlives task cancellation. If the transport cannot release held
    /// state, disconnect it rather than leave a remotely held key behind.
    @discardableResult public func finish() async -> Bool {
        await Task.detached { [self] in
            var release = RMRDPAgentEvent()
            release.kind = RMRDP_AGENT_RELEASE
            guard let sequence = session.agentHandle({ rm_rdp_agent_send($0, id, release) }) else { return false }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while sequence != 0, ContinuousClock.now < deadline {
                guard let status = session.agentHandle({ rm_rdp_agent_status($0, id, sequence, true) }) else { return false }
                if status == 1 {
                    session.agentHandle { _ in session.inputFeedback(.agent, .release) }
                    return true
                }
                if status < 0 { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            session.disconnect()
            return false
        }.value
    }
}
