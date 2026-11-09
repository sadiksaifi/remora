import Testing
@testable import RemoraCore

@Test func handoverWaitsForReleaseAndResumeRequiresANewObservation() throws {
    var control = SessionControl()
    try control.attach()
    #expect(!control.allowsHumanInput)
    #expect(control.needsFrames)
    let began = control.beginHandover(.takeOver, frame: 10)
    #expect(began)
    #expect(!control.allowsHumanInput)
    #expect(throws: SessionControl.Refusal.userActive) { try control.attach() }
    control.completeHandover()
    #expect(control.allowsHumanInput)
    control.record(.click)
    control.record(.key)
    control.record(.scroll)
    let summary = control.resume(frame: 11)
    #expect(summary?.counts == .init(clicks: 1, keys: 1, scrolls: 1))
    #expect(summary?.screenChanged == true)
    #expect(throws: SessionControl.Refusal.observationRequired) { try control.attach() }
    control.observed()
    try control.attach()
    #expect(!control.allowsHumanInput)
}

@Test func stopRefusesAgentInputUntilTheUserResumes() throws {
    var control = SessionControl()
    try control.attach()
    let began = control.beginHandover(.stop, frame: 3)
    #expect(began)
    #expect(throws: SessionControl.Refusal.agentStopped) { try control.attach() }
    control.completeHandover()
    #expect(control.state == .stopped)
    #expect(control.allowsHumanInput)
    #expect(!control.needsFrames)
    control.observed()
    #expect(throws: SessionControl.Refusal.agentStopped) { try control.attach() }
    #expect(control.canResume)
    #expect(control.resume(frame: 3) != nil)
    #expect(throws: SessionControl.Refusal.observationRequired) { try control.attach() }
    control.observed()
    try control.attach()
    #expect(control.state == .active)
    #expect(!control.allowsHumanInput)
}

@Test func releaseDetachesTheAgentWithoutBindingIt() throws {
    var control = SessionControl()
    try control.attach()
    let released = control.beginHandover(.release, frame: 3)
    #expect(released)
    #expect(!control.allowsHumanInput)
    control.completeHandover()
    #expect(control.state == .idle)
    #expect(control.allowsHumanInput)
    #expect(!control.needsFrames)
    #expect(!control.canResume)
    try control.attach()
    #expect(control.state == .active)
}

@Test func releaseCannotLiftTheUsersHold() throws {
    var paused = SessionControl()
    try paused.attach()
    paused.beginHandover(.takeOver, frame: 1)
    paused.completeHandover()
    let releasedPaused = paused.beginHandover(.release, frame: 2)
    #expect(!releasedPaused)
    #expect(throws: SessionControl.Refusal.userActive) { try paused.attach() }
    var stopped = SessionControl()
    try stopped.attach()
    stopped.beginHandover(.stop, frame: 1)
    stopped.completeHandover()
    let releasedStopped = stopped.beginHandover(.release, frame: 2)
    #expect(!releasedStopped)
    #expect(throws: SessionControl.Refusal.agentStopped) { try stopped.attach() }
}

@Test func pausePersistsAndOnlyHumanInputIsCounted() throws {
    var control = SessionControl()
    control.record(.key)
    try control.attach()
    control.record(.click)
    let began = control.beginHandover(.takeOver, frame: 8)
    #expect(began)
    control.completeHandover()
    control.observed() // A screenshot during the pause cannot satisfy Resume.
    #expect(throws: SessionControl.Refusal.userActive) { try control.attach() }
    #expect(control.resume(frame: 8)?.counts == .init())
    #expect(control.observationRequired)
    #expect(control.resume(frame: 8) == nil)
    control.invalidateObservation()
    #expect(control.observationRequired)
}

@Test func resumeFromStopCountsHumanInputAndRequiresObservation() throws {
    var control = SessionControl()
    try control.attach()
    control.beginHandover(.stop, frame: 2)
    control.completeHandover()
    control.record(.click)
    let summary = control.resume(frame: 3)
    #expect(summary?.counts.clicks == 1)
    #expect(summary?.screenChanged == true)
    #expect(throws: SessionControl.Refusal.observationRequired) { try control.attach() }
}

@Test func endingASessionSettlesHandoverAndKeepsAPause() throws {
    var control = SessionControl()
    try control.attach()
    control.beginHandover(.takeOver, frame: 2)
    control.ended()
    #expect(control.state == .paused)
    #expect(control.allowsHumanInput)
    #expect(!control.isTransferring)
    #expect(throws: SessionControl.Refusal.userActive) { try control.attach() }
    var active = SessionControl()
    try active.attach()
    active.ended()
    #expect(active.state == .stopped)
    #expect(!active.needsFrames)
}

@Test func resumeTreatsAReplacedFrameCounterAsChanged() throws {
    var control = SessionControl()
    try control.attach()
    control.beginHandover(.takeOver, frame: 1)
    control.completeHandover()
    control.invalidateObservation()
    // A new session attempt can reach the same frame number with different pixels.
    #expect(control.resume(frame: 1)?.screenChanged == true)
}

@Test func stopAllSkipsUncontrolledTabsAndStopsPausedOnes() throws {
    var idle = SessionControl()
    let stoppedIdle = idle.beginHandover(.stop, frame: 0)
    #expect(!stoppedIdle)
    var paused = SessionControl()
    try paused.attach()
    paused.beginHandover(.takeOver, frame: 4)
    paused.completeHandover()
    paused.record(.key)
    let stoppedPaused = paused.beginHandover(.stop, frame: 5)
    #expect(stoppedPaused)
    paused.completeHandover()
    #expect(paused.state == .stopped)
    let stoppedAgain = paused.beginHandover(.stop, frame: 6)
    #expect(!stoppedAgain)
    #expect(paused.resume(frame: 6)?.counts.keys == 1)
}
