import AppKit

/// Session-only chrome stays above the desktop, preserving its last rendered frame.
@MainActor
final class SessionOverlays: NSObject {
    private weak var desktop: RemoteDesktopView?
    private var reconnectingView: NSView?
    private var permissionView: NSView?
    private var offeredPermission = false
    private let cancel: () -> Void
    private static let dismissedPermissionKey = "ShortcutCapturePermissionDismissed"

    init(desktop: RemoteDesktopView, cancel: @escaping () -> Void) {
        self.desktop = desktop
        self.cancel = cancel
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func connected() {
        reconnectingView?.removeFromSuperview()
        reconnectingView = nil
        guard !offeredPermission else { return }
        offeredPermission = true
        guard !SystemShortcutCapture.isTrusted,
              !UserDefaults.standard.bool(forKey: Self.dismissedPermissionKey), let desktop else { return }
        let label = NSTextField(wrappingLabelWithString:
            "Remora needs Accessibility access to send shortcuts like Cmd-Tab to the remote computer.")
        let settings = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        let later = NSButton(title: "Not Now", target: self, action: #selector(dismissPermission))
        let stack = NSStackView(views: [label, settings, later])
        stack.spacing = 12
        let banner = NSView()
        banner.wantsLayer = true
        banner.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        banner.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: desktop.topAnchor),
            banner.leadingAnchor.constraint(equalTo: desktop.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: desktop.trailingAnchor),
            stack.topAnchor.constraint(equalTo: banner.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
        ])
        permissionView = banner
    }

    func reconnecting(attempt: Int) {
        reconnectingView?.removeFromSuperview()
        guard let desktop else { return }
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        let label = NSTextField(labelWithString: "Reconnecting... (attempt \(attempt) of 20)")
        label.textColor = .white
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelReconnect))
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 12
        shade.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        shade.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.topAnchor.constraint(equalTo: desktop.topAnchor),
            shade.bottomAnchor.constraint(equalTo: desktop.bottomAnchor),
            shade.leadingAnchor.constraint(equalTo: desktop.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: desktop.trailingAnchor),
            stack.centerXAnchor.constraint(equalTo: shade.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: shade.centerYAnchor),
        ])
        reconnectingView = shade
    }

    @objc private func cancelReconnect() { cancel() }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func dismissPermission() {
        UserDefaults.standard.set(true, forKey: Self.dismissedPermissionKey)
        permissionView?.removeFromSuperview()
        permissionView = nil
        if let desktop { desktop.window?.makeFirstResponder(desktop) }
    }

    @objc private func appBecameActive() {
        if SystemShortcutCapture.isTrusted {
            permissionView?.removeFromSuperview()
            permissionView = nil
        }
    }
}
