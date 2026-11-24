import AppKit
import RemoraCore
import SwiftUI

/// Session-only chrome stays above the desktop, preserving its last rendered frame.
@MainActor
final class SessionOverlays: NSObject {
    private weak var desktop: RemoteDesktopView?
    private var reconnectingView: NSHostingView<SessionStatusView>?
    private var permissionBanner: NSViewController?
    private var permissionView: NSView? { permissionBanner?.view }
    private var displaySwitchView: NSView?
    private var displaySwitchTask: Task<Void, Never>?
    /// Full screen has no toolbar to carry the agent's and the recording's state, so a capsule reports each change.
    private var notices = SessionNotices()
    private var noticeView: NSView?
    private var shownNotice: SessionNotices.Notice?
    private var shownAgent = ""
    private var fadingNotice: NSView?
    private var noticeTask: Task<Void, Never>?
    private var control = SessionControl.State.idle
    private var agent = ""
    /// The control state VoiceOver last heard, so repeated control events stay quiet.
    private var announced: SessionControl.State?
    private var isRecording = false
    private var offeredPermission = false
    private let computerName: String
    private let address: String
    private let cancel: () -> Void
    private let toggleControl: () -> Void
    private let stopRecording: () -> Void
    private static let dismissedPermissionKey = "ShortcutCapturePermissionDismissed"

    init(
        desktop: RemoteDesktopView, computerName: String, address: String,
        cancel: @escaping () -> Void, toggleControl: @escaping () -> Void, stopRecording: @escaping () -> Void
    ) {
        self.desktop = desktop
        self.computerName = computerName
        self.address = address
        self.cancel = cancel
        self.toggleControl = toggleControl
        self.stopRecording = stopRecording
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// Control changes post on every agent command, so VoiceOver hears only a new state or agent.
    /// It hears that control stopped only when `announcesStop` and the agent had control or was paused.
    /// In a window the toolbar's agent button shows the state. In full screen a notice does.
    func controlChanged(_ control: SessionControl, agent: String, announcesStop: Bool) {
        if !control.allowsHumanInput { removePermissionBanner() }
        let changed = control.state != self.control || agent != self.agent
        // Another program that takes the input from the first is news in full screen, like the first one was.
        if control.state == .active, self.control == .active, agent != self.agent { notices.repeatAgentNotice(at: .now) }
        self.control = control.state
        self.agent = agent
        guard changed else { return }
        let announcement: String? =
            switch control.state {
            case .active: SessionNotices.Notice.agentInControl.message(agent: agent)
            case .paused: SessionNotices.Notice.agentPaused.message(agent: agent)
            case .stopped where announcesStop && announced != nil && announced != .stopped:
                SessionNotices.Notice.agentStopped.message(agent: agent)
            case .stopped, .idle: nil
            }
        announced = announcement == nil ? nil : control.state
        if let announcement, let desktop {
            NSAccessibility.post(
                element: desktop, notification: .announcementRequested,
                userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        updateNotices()
    }

    func recordingChanged(_ isRecording: Bool) {
        guard isRecording != self.isRecording else { return }
        self.isRecording = isRecording
        updateNotices()
    }

    /// The desktop joined or left the window, or the window entered or left full screen.
    func presentationChanged() {
        notices.setPresenting(desktop?.window?.styleMask.contains(.fullScreen) == true, at: .now)
        showNotice()
    }

    /// The toolbar that slides in at the top of a full screen window carries the same state as a notice.
    func toolbarRevealed(_ revealed: Bool) {
        notices.isCovered = revealed
        showNotice()
    }

    /// The person clicked or typed while the agent holds the input.
    func inputBlocked() {
        notices.repeatAgentNotice(at: .now)
        showNotice()
    }

    private func updateNotices() {
        notices.update(control: control, isRecording: isRecording, at: .now)
        showNotice()
    }

    /// Shows what `notices` says and wakes when the notice ends.
    private func showNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        if let deadline = notices.deadline {
            noticeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                notices.advance(to: .now)
                showNotice()
            }
        }
        let notice = notices.visible
        // The revealed toolbar shows the same state, so a notice that is fading under it leaves at once too.
        if notices.isCovered, let fading = fadingNotice {
            fading.removeFromSuperview()
            fadingNotice = nil
            permissionView?.isHidden = false
        }
        guard notice != shownNotice || (notice != nil && agent != shownAgent) else { return }
        shownNotice = notice
        shownAgent = agent
        let old = noticeView
        noticeView = nil
        // A notice that is still fading leaves at once, so two never show together.
        fadingNotice?.removeFromSuperview()
        fadingNotice = nil
        guard let notice, let desktop else {
            // The revealed toolbar shows the same state, so its notice leaves at once.
            guard let old, !notices.isCovered else {
                old?.removeFromSuperview()
                permissionView?.isHidden = false
                return
            }
            // A notice whose time is up fades. The permission banner sits in the same place and returns after it.
            fadingNotice = old
            Task { @MainActor [weak self] in
                await NSAnimationContext.runAnimationGroup {
                    $0.duration = 0.3
                    old.animator().alphaValue = 0
                }
                old.removeFromSuperview()
                guard let self, fadingNotice === old else { return }
                fadingNotice = nil
                permissionView?.isHidden = false
            }
            return
        }
        old?.removeFromSuperview()
        permissionView?.isHidden = true
        let view = NSHostingView(
            rootView: SessionNoticeCapsule(
                notice: notice, agent: agent,
                action: notice == .recording ? stopRecording : toggleControl))
        view.sizingOptions = .intrinsicContentSize
        view.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(view, positioned: .below, relativeTo: reconnectingView)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: desktop.topAnchor, constant: 12),
            view.centerXAnchor.constraint(equalTo: desktop.centerXAnchor),
            view.widthAnchor.constraint(lessThanOrEqualTo: desktop.widthAnchor, constant: -24),
        ])
        noticeView = view
    }

    func connected() {
        reconnectingView?.removeFromSuperview()
        reconnectingView = nil
        guard desktop?.allowsHumanInput == true, control == .idle, !offeredPermission else { return }
        offeredPermission = true
        guard SystemShortcutCapture.isEnabled, !SystemShortcutCapture.isTrusted,
            !UserDefaults.standard.bool(forKey: Self.dismissedPermissionKey), let desktop
        else { return }
        let controller = WrappingHostingController(
            rootView: ShortcutPermissionBanner(
                onOpenSettings: { [weak self] in self?.openSettings() },
                onDismiss: { [weak self] in self?.dismissPermission() }
            ))
        controller.sizingOptions = .intrinsicContentSize
        let banner = controller.view
        banner.translatesAutoresizingMaskIntoConstraints = false
        desktop.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: desktop.topAnchor, constant: 12),
            banner.centerXAnchor.constraint(equalTo: desktop.centerXAnchor),
            banner.widthAnchor.constraint(lessThanOrEqualTo: desktop.widthAnchor, constant: -24),
        ])
        banner.isHidden = noticeView != nil
        permissionBanner = controller
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

    /// Shows a short note at the bottom of the session's page. Capture notes play the system screen capture
    /// sound, like macOS screenshots do.
    func confirm(_ message: String, systemImage: String = "checkmark.circle.fill", sound: Bool = true) {
        guard let desktop else { return }
        Self.showNote(message, systemImage: systemImage, in: desktop.superview ?? desktop)
        if sound, UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true {
            Self.captureSound?.play()
        }
    }

    /// Shows a short note at the bottom of `host` in place of the note that shows there, and tells VoiceOver.
    /// The note is not part of any capture, ignores the pointer and leaves by itself.
    static func showNote(_ message: String, systemImage: String = "checkmark.circle.fill", in host: NSView) {
        for case let shown as PassthroughHostingView<CaptureConfirmation> in host.subviews { shown.removeFromSuperview() }
        let note = PassthroughHostingView(rootView: CaptureConfirmation(message: message, systemImage: systemImage))
        note.sizingOptions = .intrinsicContentSize
        note.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(note)
        NSLayoutConstraint.activate([
            note.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            note.centerXAnchor.constraint(equalTo: host.centerXAnchor),
        ])
        NSAccessibility.post(
            element: note, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        Task { @MainActor [weak note] in
            try? await Task.sleep(for: .seconds(1.5))
            await NSAnimationContext.runAnimationGroup {
                $0.duration = 0.3
                note?.animator().alphaValue = 0
            }
            note?.removeFromSuperview()
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
        permissionBanner = nil
    }

    @objc private func appBecameActive() {
        if SystemShortcutCapture.isTrusted { removePermissionBanner() }
    }
}

/// Hosts content that wraps. The ideal size counts one line of text, so the height follows the width that
/// the constraints give the view.
private final class WrappingHostingController<Content: View>: NSHostingController<Content> {
    private lazy var height = view.heightAnchor.constraint(equalToConstant: 0)

    override func viewDidLayout() {
        super.viewDidLayout()
        guard view.bounds.width > 0 else { return }
        let fitting = sizeThatFits(in: NSSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        guard height.constant != fitting || !height.isActive else { return }
        height.constant = fitting
        height.isActive = true
    }
}

/// Lets clicks reach the desktop under a note.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
