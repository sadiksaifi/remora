import AppKit
import SwiftUI

/// Session-only chrome stays above the desktop, preserving its last rendered frame.
@MainActor
final class SessionOverlays: NSObject {
    private weak var desktop: RemoteDesktopView?
    private var reconnectingView: NSHostingView<SessionStatusView>?
    private var permissionView: NSView?
    private var offeredPermission = false
    private let computerName: String
    private let address: String
    private let cancel: () -> Void
    private static let dismissedPermissionKey = "ShortcutCapturePermissionDismissed"

    init(desktop: RemoteDesktopView, computerName: String, address: String, cancel: @escaping () -> Void) {
        self.desktop = desktop
        self.computerName = computerName
        self.address = address
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
        guard SystemShortcutCapture.isEnabled, !SystemShortcutCapture.isTrusted,
              !UserDefaults.standard.bool(forKey: Self.dismissedPermissionKey), let desktop else { return }
        let banner = NSHostingView(rootView: ShortcutPermissionBanner(
            onOpenSettings: { [weak self] in self?.openSettings() },
            onDismiss: { [weak self] in self?.dismissPermission() }
        ))
        banner.sizingOptions = .intrinsicContentSize
        banner.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: desktop.topAnchor, constant: 12),
            banner.centerXAnchor.constraint(equalTo: desktop.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualTo: desktop.widthAnchor, constant: -24),
        ])
        permissionView = banner
    }

    func reconnecting(attempt: Int) {
        let status = SessionStatusView(
            status: .reconnecting(attempt: attempt), computerName: computerName, address: address,
            overDesktop: true, onCancel: { [weak self] in self?.cancel() }
        )
        if let reconnectingView {
            reconnectingView.rootView = status
            return
        }
        guard let desktop else { return }
        let overlay = NSHostingView(rootView: status)
        overlay.sizingOptions = []
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Above the permission banner, which does not apply while the session is down.
        desktop.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: desktop.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: desktop.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: desktop.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: desktop.trailingAnchor),
        ])
        reconnectingView = overlay
    }

    private func openSettings() {
        SystemShortcutCapture.openAccessibilitySettings()
    }

    private func dismissPermission() {
        UserDefaults.standard.set(true, forKey: Self.dismissedPermissionKey)
        removePermissionBanner()
        if let desktop { desktop.window?.makeFirstResponder(desktop) }
    }

    private func removePermissionBanner() {
        permissionView?.removeFromSuperview()
        permissionView = nil
    }

    @objc private func appBecameActive() {
        if SystemShortcutCapture.isTrusted { removePermissionBanner() }
    }
}
