import AppKit
import Observation
import RemoraCore

/// The open session windows, at most one per connection.
@MainActor @Observable
final class SessionWindows {
    /// The session state each open window shows, keyed by connection ID.
    /// A connection without a session window has no entry.
    private(set) var states: [UUID: SessionState] = [:]
    @ObservationIgnored private var controllers: [UUID: SessionWindowController] = [:]
    @ObservationIgnored private let credentialStore = CredentialStore()

    func disconnectAll() {
        for controller in controllers.values { controller.disconnect() }
    }

    /// Brings the connection's session window to front, opening one if needed.
    /// A window whose session ended reconnects in place.
    /// Returns true when it started a new session.
    @discardableResult
    func show(_ connection: Connection) -> Bool {
        if let existing = controllers[connection.id] {
            existing.showWindow(nil)
            guard !existing.state.isLive else { return false }
            existing.reconnectSession(nil)
            return true
        }
        let id = connection.id
        let controller = SessionWindowController(
            connection: connection, credentialStore: credentialStore,
            onStateChange: { [weak self] state in self?.states[id] = state },
            onClose: { [weak self] _ in
                self?.controllers[id] = nil
                self?.states[id] = nil
            }
        )
        controllers[id] = controller
        states[id] = controller.state
        controller.showWindow(nil)
        return true
    }

    /// Ends the connection's session the way Session > Disconnect does. The window stays open.
    func disconnect(_ id: UUID) {
        controllers[id]?.disconnectSession(nil)
    }
}

extension SessionState {
    /// True until the session ends. A live session can be disconnected; an ended one reconnects.
    var isLive: Bool {
        if case .disconnected = self { false } else { true }
    }
}
