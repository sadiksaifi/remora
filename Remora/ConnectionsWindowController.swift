import AppKit
import RemoraCore

@MainActor
final class ConnectionsWindowController: NSWindowController {
    private let connectionsViewController: ConnectionsViewController

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore) {
        connectionsViewController = ConnectionsViewController(
            connectionStore: connectionStore,
            credentialStore: credentialStore
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connections"
        window.minSize = NSSize(width: 400, height: 280)
        window.isReleasedWhenClosed = false
        window.contentViewController = connectionsViewController
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connectionStore:credentialStore:)")
    }

    func newConnection(_ sender: Any?) {
        connectionsViewController.newConnection(sender)
    }
}
