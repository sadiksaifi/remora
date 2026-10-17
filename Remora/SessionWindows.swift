import AppKit
import RemoraCore

/// The open session windows, at most one per connection.
@MainActor
final class SessionWindows {
    private var controllers: [UUID: SessionWindowController] = [:]
    private var cascadePoint = NSPoint.zero

    /// Brings the connection's session window to front, opening one if needed.
    /// Returns true when it opened a new session.
    @discardableResult
    func show(_ connection: Connection) -> Bool {
        if let existing = controllers[connection.id] {
            existing.showWindow(nil)
            return false
        }
        let controller = SessionWindowController(connection: connection) { [weak self] closed in
            self?.controllers[closed.connection.id] = nil
        }
        controllers[connection.id] = controller
        if let window = controller.window {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.showWindow(nil)
        return true
    }
}
