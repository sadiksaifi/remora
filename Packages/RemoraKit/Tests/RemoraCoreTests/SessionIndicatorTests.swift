import RemoraCore
import Testing

private func indicator(
    _ state: SessionState, waiting: Bool = false, control: SessionControl.State = .idle, recording: Bool = false
) -> SessionIndicator {
    SessionIndicator(state: state, hasWaitingRequest: waiting, control: control, isRecording: recording)
}

@Test func aConnectedSessionWithNothingToReportShowsNoEvent() {
    #expect(indicator(.connected) == .none)
    #expect(indicator(.connected, control: .stopped) == .none)
}

@Test func aRequestOrAFailureOutranksEverything() {
    #expect(indicator(.awaitingCredentials) == .needsAttention)
    #expect(indicator(.awaitingTrust) == .needsAttention)
    #expect(indicator(.connected, waiting: true, control: .active, recording: true) == .needsAttention)
    let failures: [DisconnectReason] = [
        .authenticationFailed, .certificateRejected, .hostNotFound, .connectionRefused, .connectionTimedOut, .localNetworkDenied,
        .protocolError("bad handshake"),
    ]
    for reason in failures { #expect(indicator(.disconnected(reason), control: .paused) == .needsAttention) }
}

@Test func connectingOutranksTheAgentAndARecording() {
    #expect(indicator(.connecting, control: .active) == .connecting)
    #expect(indicator(.reconnecting(attempt: 3), control: .active, recording: true) == .connecting)
}

@Test func aSessionThatEndedWithoutAFailureShowsDisconnected() {
    #expect(indicator(.disconnected(nil)) == .disconnected)
    #expect(indicator(.disconnected(.cancelledByUser), control: .paused) == .disconnected)
    #expect(indicator(.disconnected(.serverEndedSession("The administrator signed you out."))) == .disconnected)
}

@Test func theAgentInControlOutranksARecordingAndARecordingOutranksAPausedAgent() {
    #expect(indicator(.connected, control: .active) == .agentInControl)
    #expect(indicator(.connected, control: .active, recording: true) == .agentInControl)
    #expect(indicator(.connected, recording: true) == .recording)
    #expect(indicator(.connected, control: .paused, recording: true) == .recording)
    #expect(indicator(.connected, control: .paused) == .agentPaused)
}
