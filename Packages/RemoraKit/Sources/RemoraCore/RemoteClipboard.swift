/// Clipboard state for one session attempt. Revisions order notifications from channel workers.
/// A new offer invalidates old text, including an offer with no text format.
public struct RemoteClipboard: Sendable {
    public enum Status: Sendable, Equatable {
        case notReady, unknown, pending, unavailable
        case text(String)
        case offered(String)
        case failed
    }
    public private(set) var status: Status = .notReady
    private var revision: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func update(revision: UInt64, status: Status) -> Bool {
        guard revision > self.revision else { return false }
        self.revision = revision
        self.status = status
        return true
    }
}
