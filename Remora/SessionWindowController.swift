import AppKit
import RemoraCore

/// Owns one session's lifecycle. Closing the window ends the session.
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let connection: Connection
    private let onClose: (SessionWindowController) -> Void

    init(connection: Connection, onClose: @escaping (SessionWindowController) -> Void) {
        self.connection = connection
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = connection.name
        window.subtitle = connection.displayAddress
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "Session"
        window.contentView = Self.connectingView(name: connection.name)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connection:onClose:)")
    }

    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }

    private static func connectingView(name: String) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .regular
        progress.startAnimation(nil)

        let label = NSTextField(labelWithString: "Connecting to \(name)…")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [progress, label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])
        return view
    }
}
