import AppKit
import RemoraCore

/// The open session windows, at most one per connection.
@MainActor
final class SessionWindows {
    private var controllers: [UUID: SessionWindowController] = [:]
    private let credentialStore = CredentialStore()

    func disconnectAll() {
        for controller in controllers.values { controller.disconnect() }
    }

    /// Brings the connection's session window to front, opening one if needed.
    /// Returns true when it opened a new session.
    @discardableResult
    func show(_ connection: Connection) -> Bool {
        if let existing = controllers[connection.id] {
            existing.showWindow(nil)
            return false
        }
        let controller = SessionWindowController(connection: connection, credentialStore: credentialStore) { [weak self] closed in
            self?.controllers[closed.connection.id] = nil
        }
        controllers[connection.id] = controller
        controller.showWindow(nil)
        return true
    }
}
