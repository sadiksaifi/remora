import Foundation

public struct AgentInputCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let unicode = Self(rawValue: 1)
    public static let extendedButtons = Self(rawValue: 2)
    public static let horizontalWheel = Self(rawValue: 4)
}

public enum AgentInputEvent: Sendable {
    case key(PhysicalKey, down: Bool)
    case pointer(RemotePoint, PointerButtons)
    case wheel(WheelInput)
    case unicode(Unicode.Scalar)
    case pause
}

public enum AgentInputFailure: Error, Sendable {
    case sessionEnded, cancelled, submissionFailed, timedOut
}

/// Protocol-neutral automation with independent ownership of held input.
public protocol AgentInputSession: RemoteSession {
    var inputCapabilities: AgentInputCapabilities { get }
    func beginAgentInput() -> (any AgentInputRequest)?
}

/// Sends acknowledge transport submission, not delivery or application handling.
/// Always finish an admitted request, including after cancellation.
public protocol AgentInputRequest: Sendable {
    func cancel()
    func send(_ event: AgentInputEvent, deadline: ContinuousClock.Instant) async throws
    @discardableResult func finish() async -> Bool
}
