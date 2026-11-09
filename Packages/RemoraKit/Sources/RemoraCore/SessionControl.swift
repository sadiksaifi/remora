/// Per-session input ownership. Handover keeps human forwarding closed until
/// the adapter confirms that canceled agent input has released its held state.
public struct SessionControl: Sendable {
    public enum State: String, Sendable { case idle, active, paused, stopped }
    public enum Refusal: Error { case userActive, agentStopped, observationRequired, inputBusy }
    public enum HumanInput: Sendable { case click, key, scroll }
    /// Take Over and Stop come from the user and bind the agent until Resume.
    /// Release comes from the agent and lets its next input attach again.
    public enum Handover: Sendable { case takeOver, stop, release }
    public struct Counts: Sendable, Equatable {
        public var clicks: Int
        public var keys: Int
        public var scrolls: Int
        public init(clicks: Int = 0, keys: Int = 0, scrolls: Int = 0) {
            self.clicks = clicks; self.keys = keys; self.scrolls = scrolls
        }
    }
    public struct Summary: Sendable, Equatable {
        public let counts: Counts
        public let screenChanged: Bool
    }
    public private(set) var state: State = .idle
    public private(set) var observationRequired = false
    public private(set) var counts = Counts()
    public private(set) var lastResume: Summary?
    public private(set) var resumeRevision = 0
    private var handover: State?
    private var pauseFrame: Int?

    public init() {}
    public var isTransferring: Bool { handover != nil }
    public var allowsHumanInput: Bool { state != .active && handover == nil }
    public var needsFrames: Bool { state == .active || state == .paused }
    public var canTakeOver: Bool { state == .active && handover == nil }
    public var canResume: Bool { (state == .paused || state == .stopped) && handover == nil }
    public var canStop: Bool { needsFrames && handover == nil }

    public func checkInput() throws {
        if handover == .paused || state == .paused { throw Refusal.userActive }
        if handover == .stopped || state == .stopped { throw Refusal.agentStopped }
        if handover != nil { throw Refusal.inputBusy }
        if observationRequired { throw Refusal.observationRequired }
    }

    public mutating func attach() throws {
        try checkInput()
        state = .active
    }

    @discardableResult
    public mutating func beginHandover(_ kind: Handover, frame: Int) -> Bool {
        guard kind == .stop ? canStop : canTakeOver else { return false }
        handover = switch kind { case .takeOver: .paused; case .stop: .stopped; case .release: .idle }
        if state == .active { counts = Counts(); pauseFrame = frame }
        return true
    }

    public mutating func completeHandover() {
        guard let handover else { return }
        state = handover
        self.handover = nil
        if state == .idle { observationRequired = false }
    }

    public mutating func resume(frame: Int) -> Summary? {
        guard canResume else { return nil }
        let summary = Summary(counts: counts, screenChanged: frame != pauseFrame)
        lastResume = summary
        resumeRevision += 1
        state = .active
        observationRequired = true
        return summary
    }

    public mutating func record(_ input: HumanInput) {
        guard state == .paused || state == .stopped, allowsHumanInput else { return }
        switch input {
        case .click: counts.clicks += 1
        case .key: counts.keys += 1
        case .scroll: counts.scrolls += 1
        }
    }

    /// Settles a pending handover. The user's pause or stop survives, so only Resume returns control.
    /// Active control is released, so the agent can attach to a later connection.
    public mutating func ended() {
        if let handover { state = handover } else if state == .active { state = .idle }
        handover = nil
        observationRequired = false
    }

    public mutating func observed() {
        if state != .paused && !isTransferring { observationRequired = false }
    }

    public mutating func invalidateObservation() {
        pauseFrame = nil
        if needsFrames { observationRequired = true }
    }
}
