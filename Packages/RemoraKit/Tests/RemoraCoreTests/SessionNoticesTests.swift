import RemoraCore
import Testing

private let start = ContinuousClock.now
private func after(_ seconds: Double) -> ContinuousClock.Instant { start + .seconds(seconds) }

/// Notices for a session that is on screen in full screen, with nothing to report yet.
private func presenting() -> SessionNotices {
    var notices = SessionNotices()
    notices.setPresenting(true, at: start)
    return notices
}

@Test func aWindowedSessionShowsNoNotice() {
    var notices = SessionNotices()
    notices.update(control: .active, isRecording: true, at: start)
    notices.repeatAgentNotice(at: after(1))
    #expect(notices.visible == nil)
    #expect(notices.deadline == nil)
}

@Test func aChangeShowsItsNoticeForFourSeconds() {
    var notices = presenting()
    notices.update(control: .active, isRecording: false, at: start)
    #expect(notices.visible == .agentInControl)
    #expect(notices.deadline == after(4))
    notices.advance(to: after(3.9))
    #expect(notices.visible == .agentInControl)
    notices.advance(to: after(4))
    #expect(notices.visible == nil)
    #expect(notices.deadline == nil)
}

@Test func anUnchangedStateDoesNotShowItsNoticeAgain() {
    var notices = presenting()
    notices.update(control: .active, isRecording: false, at: start)
    notices.advance(to: after(4))
    notices.update(control: .active, isRecording: false, at: after(5))
    #expect(notices.visible == nil)
}

@Test func eachAgentChangeReplacesTheNoticeBeforeIt() {
    var notices = presenting()
    notices.update(control: .active, isRecording: false, at: start)
    notices.update(control: .paused, isRecording: false, at: after(1))
    #expect(notices.visible == .agentPaused)
    #expect(notices.deadline == after(5))
    notices.update(control: .stopped, isRecording: false, at: after(2))
    #expect(notices.visible == .agentStopped)
    notices.update(control: .active, isRecording: false, at: after(3))
    #expect(notices.visible == .agentInControl)
}

@Test func anAgentThatReleasesControlTakesItsNoticeAway() {
    var notices = presenting()
    notices.update(control: .active, isRecording: false, at: start)
    notices.update(control: .idle, isRecording: false, at: after(1))
    #expect(notices.visible == nil)
}

@Test func anAgentThatReleasesControlLetsTheWaitingRecordingNoticeShow() {
    var notices = presenting()
    notices.update(control: .active, isRecording: true, at: start)
    notices.update(control: .idle, isRecording: true, at: after(1))
    #expect(notices.visible == .recording)
    #expect(notices.deadline == after(5))
}

@Test func twoChangesTogetherShowTheAgentFirstThenTheRecording() {
    var notices = presenting()
    notices.update(control: .active, isRecording: true, at: start)
    #expect(notices.visible == .agentInControl)
    notices.advance(to: after(4))
    #expect(notices.visible == .recording)
    #expect(notices.deadline == after(8))
    notices.advance(to: after(8))
    #expect(notices.visible == nil)
}

@Test func anAgentNoticeInterruptsARecordingNoticeWhichReturnsAfterIt() {
    var notices = presenting()
    notices.update(control: .idle, isRecording: true, at: start)
    #expect(notices.visible == .recording)
    notices.update(control: .active, isRecording: true, at: after(1))
    #expect(notices.visible == .agentInControl)
    notices.advance(to: after(5))
    #expect(notices.visible == .recording)
}

@Test func aRecordingThatStopsTakesItsNoticeAway() {
    var notices = presenting()
    notices.update(control: .idle, isRecording: true, at: start)
    notices.update(control: .idle, isRecording: false, at: after(1))
    #expect(notices.visible == nil)

    notices.update(control: .active, isRecording: true, at: after(2))
    notices.update(control: .active, isRecording: false, at: after(3))
    notices.advance(to: after(6))
    #expect(notices.visible == nil)
}

@Test func blockedInputBringsTheAgentNoticeBackForFourSeconds() {
    var notices = presenting()
    notices.update(control: .active, isRecording: false, at: start)
    notices.advance(to: after(4))
    notices.repeatAgentNotice(at: after(10))
    #expect(notices.visible == .agentInControl)
    #expect(notices.deadline == after(14))
    notices.repeatAgentNotice(at: after(12))
    #expect(notices.deadline == after(16))
}

@Test func aRepeatedAgentNoticeLetsTheRecordingNoticeWaitAgain() {
    var notices = presenting()
    notices.update(control: .active, isRecording: true, at: start)
    notices.advance(to: after(4))
    #expect(notices.visible == .recording)
    notices.repeatAgentNotice(at: after(5))
    #expect(notices.visible == .agentInControl)
    notices.advance(to: after(9))
    #expect(notices.visible == .recording)
    #expect(notices.deadline == after(13))
}

@Test func inputThatIsNotBlockedByAnAgentShowsNothing() {
    var notices = presenting()
    notices.update(control: .paused, isRecording: false, at: start)
    notices.advance(to: after(4))
    notices.repeatAgentNotice(at: after(5))
    #expect(notices.visible == nil)
}

@Test func enteringFullScreenShowsWhatIsAlreadyHappening() {
    var notices = SessionNotices()
    notices.update(control: .paused, isRecording: true, at: start)
    notices.setPresenting(true, at: after(1))
    #expect(notices.visible == .agentPaused)
    notices.advance(to: after(5))
    #expect(notices.visible == .recording)
}

@Test func leavingFullScreenDropsTheNoticeAndTheOneWaiting() {
    var notices = presenting()
    notices.update(control: .active, isRecording: true, at: start)
    notices.setPresenting(false, at: after(1))
    #expect(notices.visible == nil)
    #expect(notices.deadline == nil)
    notices.advance(to: after(4))
    #expect(notices.visible == nil)
}

@Test func theRevealedToolbarHidesTheNoticeWithoutStoppingItsClock() {
    var notices = presenting()
    notices.update(control: .active, isRecording: false, at: start)
    notices.isCovered = true
    #expect(notices.visible == nil)
    #expect(notices.deadline == after(4))
    notices.isCovered = false
    #expect(notices.visible == .agentInControl)
}
