import AppKit
import SwiftUI

/// Session-only chrome stays above the desktop, preserving its last rendered frame.
@MainActor
final class SessionOverlays: NSObject {
    private weak var desktop: RemoteDesktopView?
    private var reconnectingView: NSHostingView<SessionStatusView>?
    private var permissionView: NSView?
    private var confirmationView: NSView?
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

    /// Shows a short note at the bottom of the desktop and plays the system screen capture sound, like
    /// macOS screenshots do. The note is not part of any capture and ignores the pointer.
    func confirm(_ message: String) {
        confirmationView?.removeFromSuperview()
        guard let desktop else { return }
        let note = PassthroughHostingView(rootView: CaptureConfirmation(message: message))
        note.sizingOptions = .intrinsicContentSize
        note.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(note)
        NSLayoutConstraint.activate([
            note.bottomAnchor.constraint(equalTo: desktop.bottomAnchor, constant: -16),
            note.centerXAnchor.constraint(equalTo: desktop.centerXAnchor),
        ])
        confirmationView = note
        NSAccessibility.post(element: note, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true {
            Self.captureSound?.play()
        }
        Task { @MainActor [weak self, weak note] in
            try? await Task.sleep(for: .seconds(1.5))
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; note?.animator().alphaValue = 0 }
            note?.removeFromSuperview()
            if let self, confirmationView === note { confirmationView = nil }
        }
    }

    private static let captureSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true
    )

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

/// Lets clicks reach the desktop under a note.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
