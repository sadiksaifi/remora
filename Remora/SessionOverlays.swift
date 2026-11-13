import AppKit
import RemoraCore
import SwiftUI

/// Session-only chrome stays above the desktop, preserving its last rendered frame.
@MainActor
final class SessionOverlays: NSObject {
    private weak var desktop: RemoteDesktopView?
    private var reconnectingView: NSHostingView<SessionStatusView>?
    private var permissionView: NSView?
    private var confirmationView: NSView?
    private var capsuleView: NSView?
    private var displaySwitchView: NSView?
    private var displaySwitchTask: Task<Void, Never>?
    private var capsule: AgentControlCapsule?
    private var offeredPermission = false
    private let computerName: String
    private let address: String
    private let cancel: () -> Void
    private let toggleControl: () -> Void
    private static let dismissedPermissionKey = "ShortcutCapturePermissionDismissed"

    init(
        desktop: RemoteDesktopView, computerName: String, address: String,
        cancel: @escaping () -> Void, toggleControl: @escaping () -> Void
    ) {
        self.desktop = desktop
        self.computerName = computerName
        self.address = address
        self.cancel = cancel
        self.toggleControl = toggleControl
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// Control changes post on every agent command, so only a new capsule state replaces the capsule.
    /// The stopped capsule shows only when `showsStop` and the agent had control or was paused; it fades after 4 s.
    func controlChanged(_ control: SessionControl, agent: String, showsStop: Bool) {
        if !control.allowsHumanInput { removePermissionBanner() }
        let next: AgentControlCapsule?
        switch control.state {
        case .active, .paused:
            next = AgentControlCapsule(state: control.state, agent: agent, action: toggleControl)
        case .stopped where showsStop && capsule != nil && capsule?.state != .stopped:
            next = AgentControlCapsule(state: .stopped, agent: capsule?.agent ?? agent, action: toggleControl)
        case .stopped where capsule?.state == .stopped:
            return
        default:
            next = nil
        }
        guard next?.state != capsule?.state || next?.agent != capsule?.agent else { return }
        capsule = next
        capsuleView?.removeFromSuperview()
        capsuleView = nil
        guard let next, let desktop else { return }
        removePermissionBanner()
        let view = NSHostingView(rootView: next)
        view.sizingOptions = .intrinsicContentSize
        view.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(view, positioned: .below, relativeTo: reconnectingView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: desktop.topAnchor, constant: 12),
            view.centerXAnchor.constraint(equalTo: desktop.centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: desktop.widthAnchor, constant: -24),
        ])
        capsuleView = view
        NSAccessibility.post(
            element: view, notification: .announcementRequested,
            userInfo: [.announcement: next.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard next.state == .stopped else { return }
        Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, let view, capsuleView === view else { return }
            await NSAnimationContext.runAnimationGroup {
                $0.duration = 0.3
                view.animator().alphaValue = 0
            }
            guard capsuleView === view else { return }
            view.removeFromSuperview()
            capsuleView = nil
            capsule = nil
        }
    }

    func connected() {
        reconnectingView?.removeFromSuperview()
        reconnectingView = nil
        guard desktop?.allowsHumanInput == true, capsuleView == nil, !offeredPermission else { return }
        offeredPermission = true
        guard SystemShortcutCapture.isEnabled, !SystemShortcutCapture.isTrusted,
            !UserDefaults.standard.bool(forKey: Self.dismissedPermissionKey), let desktop
        else { return }
        let banner = NSHostingView(
            rootView: ShortcutPermissionBanner(
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

    /// Dims the last frame under a switching or failure capsule, or removes it for nil. The dimming takes
    /// the pointer, so clicks don't reach a desktop that is switching. `delay` keeps fast switches quiet.
    func showDisplaySwitch(_ status: DisplaySwitchStatus?, after delay: Duration = .zero) {
        displaySwitchTask?.cancel()
        displaySwitchTask = nil
        guard let status else {
            displaySwitchView?.removeFromSuperview()
            displaySwitchView = nil
            return
        }
        guard delay > .zero else { return presentDisplaySwitch(status) }
        displaySwitchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.presentDisplaySwitch(status)
        }
    }

    private func presentDisplaySwitch(_ status: DisplaySwitchStatus) {
        if let view = displaySwitchView as? NSHostingView<DisplaySwitchStatus> {
            view.rootView = status
        } else if let desktop {
            let view = NSHostingView(rootView: status)
            view.sizingOptions = []
            view.translatesAutoresizingMaskIntoConstraints = false
            desktop.addSubview(view, positioned: .below, relativeTo: reconnectingView)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: desktop.topAnchor),
                view.bottomAnchor.constraint(equalTo: desktop.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: desktop.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: desktop.trailingAnchor),
            ])
            displaySwitchView = view
        }
        guard let displaySwitchView else { return }
        NSAccessibility.post(
            element: displaySwitchView, notification: .announcementRequested,
            userInfo: [.announcement: status.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Shows a short note at the bottom of the desktop. Capture notes play the system screen capture sound,
    /// like macOS screenshots do. The note is not part of any capture and ignores the pointer.
    func confirm(_ message: String, systemImage: String = "checkmark.circle.fill", sound: Bool = true) {
        confirmationView?.removeFromSuperview()
        guard let desktop else { return }
        let note = PassthroughHostingView(rootView: CaptureConfirmation(message: message, systemImage: systemImage))
        note.sizingOptions = .intrinsicContentSize
        note.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(note)
        NSLayoutConstraint.activate([
            note.bottomAnchor.constraint(equalTo: desktop.bottomAnchor, constant: -16),
            note.centerXAnchor.constraint(equalTo: desktop.centerXAnchor),
        ])
        confirmationView = note
        NSAccessibility.post(
            element: note, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        if sound, UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true {
            Self.captureSound?.play()
        }
        Task { @MainActor [weak self, weak note] in
            try? await Task.sleep(for: .seconds(1.5))
            await NSAnimationContext.runAnimationGroup {
                $0.duration = 0.3
                note?.animator().alphaValue = 0
            }
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
