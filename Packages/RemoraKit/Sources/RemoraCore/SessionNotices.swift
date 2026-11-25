/// The notice a full screen session shows at the top of the remote screen, where no toolbar carries its state.
/// One notice shows at a time, for `duration`, and the agent's comes before a recording's.
/// The caller passes the time in and wakes at `deadline` to call `advance(to:)`.
public struct SessionNotices: Sendable {
    public enum Notice: Sendable, Equatable {
        case agentInControl, agentPaused, agentStopped, recording
    }

    public static let duration: Duration = .seconds(4)

    /// The revealed toolbar carries the same state, so it hides the notice. The notice's clock keeps running.
    public var isCovered = false
    private var isPresenting = false
    private var control: SessionControl.State = .idle
    private var isRecording = false
    private var current: (notice: Notice, until: ContinuousClock.Instant)?
    /// A recording notice waits for the agent's notice to finish.
    private var recordingWaits = false

    public init() {}

    public var visible: Notice? { isCovered ? nil : current?.notice }
    /// When the showing notice ends, or nil while none shows.
    public var deadline: ContinuousClock.Instant? { current?.until }

    /// Shows a notice for each state that changed since the last call.
    public mutating func update(control: SessionControl.State, isRecording: Bool, at now: ContinuousClock.Instant) {
        let previous = self.control
        self.control = control
        if control != previous, isPresenting {
            switch control {
            case .active: show(.agentInControl, at: now)
            case .paused: show(.agentPaused, at: now)
            case .stopped: show(.agentStopped, at: now)
            case .idle: if current?.notice != .recording { finish(at: now) }
            }
        }
        guard isRecording != self.isRecording else { return }
        self.isRecording = isRecording
        if !isRecording {
            recordingWaits = false
            if current?.notice == .recording { current = nil }
        } else if isPresenting {
            show(.recording, at: now)
        }
    }

    /// True while the session is on screen in full screen. Turning it on shows what is already happening.
    public mutating func setPresenting(_ presenting: Bool, at now: ContinuousClock.Instant) {
        guard presenting != isPresenting else { return }
        isPresenting = presenting
        current = nil
        recordingWaits = false
        guard presenting else { return }
        switch control {
        case .active: show(.agentInControl, at: now)
        case .paused: show(.agentPaused, at: now)
        case .idle, .stopped: break
        }
        if isRecording { show(.recording, at: now) }
    }

    /// Shows the agent's notice again while the agent holds the input. The person clicked or typed, and without
    /// the notice the screen would look frozen. Or another program took the input, and the notice names it.
    /// True when the notice had ended and this brought it back, also under the revealed toolbar.
    @discardableResult
    public mutating func repeatAgentNotice(at now: ContinuousClock.Instant) -> Bool {
        guard isPresenting, control == .active else { return false }
        let hadEnded = current.map { $0.notice != .agentInControl || now >= $0.until } ?? true
        show(.agentInControl, at: now)
        return hadEnded
    }

    /// Ends the notice whose time has passed and shows the recording notice that waited for it.
    public mutating func advance(to now: ContinuousClock.Instant) {
        guard let current, now >= current.until else { return }
        finish(at: now)
    }

    /// Ends the showing notice and shows the recording notice that waited for it.
    private mutating func finish(at now: ContinuousClock.Instant) {
        current = nil
        if recordingWaits {
            recordingWaits = false
            show(.recording, at: now)
        }
    }

    private mutating func show(_ notice: Notice, at now: ContinuousClock.Instant) {
        if notice == .recording {
            if let current, current.notice != .recording {
                recordingWaits = true
                return
            }
        } else if current?.notice == .recording {
            recordingWaits = true
        }
        current = (notice, now + Self.duration)
    }
}
