/// The one status a session shows where there is room for one: its tab icon and its row in the connections list.
/// The cases are in priority order. The first that applies wins, and the state the person must act on comes first.
public enum SessionIndicator: Sendable, Equatable {
    /// A credentials or certificate request waits, the connection failed, or a capture failure waits to be read.
    case needsAttention
    case connecting
    /// The person disconnected, or the remote computer ended the session.
    case disconnected
    case agentInControl
    case recording
    case agentPaused
    /// Connected, with nothing else to report.
    case none

    /// - Parameters:
    ///   - hasWaitingRequest: A request or a failure message waits until the session's tab shows.
    ///   - isRecording: The session records, or finishes writing a recording.
    public init(state: SessionState, hasWaitingRequest: Bool, control: SessionControl.State, isRecording: Bool) {
        self =
            if hasWaitingRequest {
                .needsAttention
            } else {
                switch state {
                case .awaitingCredentials, .awaitingTrust: .needsAttention
                case .connecting, .reconnecting: .connecting
                case .disconnected(let reason): reason?.isFailure == true ? .needsAttention : .disconnected
                case .connected:
                    switch (control, isRecording) {
                    case (.active, _): .agentInControl
                    case (_, true): .recording
                    case (.paused, false): .agentPaused
                    case (.idle, false), (.stopped, false): SessionIndicator.none
                    }
                }
            }
    }
}

extension DisconnectReason {
    /// False when the person disconnected or the remote computer ended the session. Those are ordinary endings.
    public var isFailure: Bool {
        switch self {
        case .cancelledByUser, .serverEndedSession: false
        case .authenticationFailed, .certificateRejected, .hostNotFound, .connectionRefused, .connectionTimedOut, .localNetworkDenied, .protocolError: true
        }
    }
}
