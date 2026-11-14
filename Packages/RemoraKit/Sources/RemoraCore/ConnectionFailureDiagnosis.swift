import Foundation
import Network
import os

/// Refines a transport failure only when macOS explicitly reports Local Network denial.
/// Call on the session worker after closing the failed transport, never on the main thread.
public struct ConnectionFailureDiagnosis: Sendable {
    public enum Access: Sendable { case localNetworkDenied, unconfirmed }
    private let inspect: @Sendable (String, UInt16, @Sendable () -> Bool) -> Access

    public init(inspect: @escaping @Sendable (String, UInt16, @Sendable () -> Bool) -> Access) {
        self.inspect = inspect
    }

    public static let system = Self(inspect: inspectSystem)

    public func diagnose(
        _ reason: DisconnectReason?, host: String, port: UInt16,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> DisconnectReason? {
        guard reason == .connectionTimedOut else { return reason }
        guard !isCancelled() else { return .cancelledByUser }
        let access = inspect(host, port, isCancelled)
        guard !isCancelled() else { return .cancelledByUser }
        return access == .localNetworkDenied ? .localNetworkDenied : reason
    }
}

/// A failed BSD connect does not expose NWPath's localNetworkDenied reason. Make one
/// bounded TCP attempt to the same endpoint, without sending protocol data. A ready
/// path is not proof of permission for the failed socket or of server health.
private func inspectSystem(host: String, port: UInt16, isCancelled: @Sendable () -> Bool) -> ConnectionFailureDiagnosis.Access {
    guard let port = NWEndpoint.Port(rawValue: port), !isCancelled() else { return .unconfirmed }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    let result = OSAllocatedUnfairLock<ConnectionFailureDiagnosis.Access?>(initialState: nil)
    let completed = DispatchSemaphore(value: 0)
    let log = Logger(subsystem: "dev.sadiksaifi.Remora", category: "NetworkAccess")
    let attempt = UUID().uuidString
    connection.stateUpdateHandler = { [weak connection] state in
        guard let connection else { return }
        let access: ConnectionFailureDiagnosis.Access
        switch state {
        case .waiting, .failed:
            access = connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .localNetworkDenied : .unconfirmed
        case .ready: access = .unconfirmed
        default: return
        }
        log.notice(
            "Transport diagnosis attempt=\(attempt, privacy: .public) state=\(String(describing: state), privacy: .public) path=\(String(describing: connection.currentPath), privacy: .public)"
        )
        result.withLock { value in
            guard value == nil else { return }
            value = access
            completed.signal()
        }
    }
    connection.start(queue: DispatchQueue(label: "Remora network diagnosis"))
    defer { connection.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !isCancelled(), ContinuousClock.now < deadline {
        if completed.wait(timeout: .now() + .milliseconds(50)) == .success {
            return result.withLock { $0 ?? .unconfirmed }
        }
    }
    let cancelled = isCancelled()
    log.notice("Transport diagnosis attempt=\(attempt, privacy: .public) ended without a confirmed denial cancelled=\(cancelled, privacy: .public)")
    return .unconfirmed
}
