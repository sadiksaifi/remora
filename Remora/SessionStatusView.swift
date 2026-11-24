import RemoraCore
import SwiftUI

/// What a session window shows instead of, or over, the remote desktop.
enum SessionStatus: Equatable {
    case connecting
    case awaitingCredentials
    case awaitingTrust
    case reconnecting(attempt: Int)
    case disconnected(DisconnectReason?)
}

/// Centered status for a session window. Over the desktop it sits on a glass panel.
struct SessionStatusView: View {
    /// FreeRDP's reconnect loop in the bridge stops after this many attempts. VNC sessions don't reconnect automatically.
    static let reconnectAttemptLimit = 20

    let status: SessionStatus
    let computerName: String
    let address: String
    var overDesktop = false
    /// After a session ends, Close takes the keyboard when the status appears.
    var focusesClose = false
    var onCancel: () -> Void = {}
    var onReconnect: () -> Void = {}
    var onClose: () -> Void = {}
    @FocusState private var closeFocused: Bool

    var body: some View {
        if overDesktop {
            ZStack {
                Color.black.opacity(0.4)
                content
                    .padding(28)
                    .frame(minWidth: 320)
                    .glassEffect(.regular, in: .rect(cornerRadius: 26))
            }
        } else {
            content
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        VStack(spacing: 16) {
            header
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                if case .disconnected(let reason) = status, let recovery = reason?.recoverySuggestion {
                    Text(recovery).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)
            actions
                .controlSize(.large)
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch status {
        case .connecting, .reconnecting:
            ProgressView()
                .controlSize(.large)
                .frame(height: 54)
        case .awaitingCredentials:
            symbol("person.badge.key")
        case .awaitingTrust:
            symbol("checkmark.shield")
        case .disconnected(let reason):
            symbol(Self.symbolName(for: reason))
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 46, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(height: 54)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .connecting, .reconnecting:
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sessionCancel")
        case .awaitingCredentials, .awaitingTrust:
            EmptyView()
        case .disconnected(let reason):
            if reason?.recoverySuggestion != nil {
                Button("Open Privacy & Security Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Close Tab", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .focused($closeFocused)
                    .accessibilityIdentifier("sessionClose")
                Button("Reconnect", action: onReconnect)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sessionReconnect")
            }
            .onAppear { closeFocused = focusesClose }
        }
    }

    private var title: String {
        switch status {
        case .connecting: "Connecting to “\(computerName)”"
        case .awaitingCredentials: "Waiting for Credentials"
        case .awaitingTrust: "Waiting for Approval"
        case .reconnecting: "Reconnecting to “\(computerName)”"
        case .disconnected(let reason): Self.title(for: reason)
        }
    }

    private var message: String {
        switch status {
        case .connecting: address
        case .awaitingCredentials: "Enter your credentials to connect to \(address)."
        case .awaitingTrust: "Review the certificate for \(address) to continue."
        case .reconnecting(let attempt): "Attempt \(attempt) of \(Self.reconnectAttemptLimit)"
        case .disconnected(let reason): message(for: reason)
        }
    }

    private static func symbolName(for reason: DisconnectReason?) -> String {
        switch reason {
        case .authenticationFailed: "person.crop.circle.badge.exclamationmark"
        case .certificateRejected: "lock.trianglebadge.exclamationmark"
        case .hostNotFound, .connectionRefused, .localNetworkDenied: "network.slash"
        case .connectionTimedOut: "clock.badge.exclamationmark"
        case .protocolError: "exclamationmark.triangle"
        case .serverEndedSession, .cancelledByUser, nil: "display"
        }
    }

    static func title(for reason: DisconnectReason?) -> String {
        switch reason {
        case .authenticationFailed: "Authentication Failed"
        case .certificateRejected: "Certificate Not Trusted"
        case .hostNotFound: "Computer Not Found"
        case .connectionRefused: "Connection Refused"
        case .connectionTimedOut: "Connection Timed Out"
        case .localNetworkDenied: "Local Network Access Denied"
        case .protocolError: "Couldn’t Connect"
        case .serverEndedSession, nil: "Session Ended"
        case .cancelledByUser: "Disconnected"
        }
    }

    private func message(for reason: DisconnectReason?) -> String {
        switch reason {
        case .authenticationFailed:
            "\(address) didn’t accept the username or password."
        case .certificateRejected:
            "Remora didn’t connect because the certificate for \(address) wasn’t trusted."
        case .hostNotFound:
            "Remora couldn’t find \(address). Check the host name and your network connection."
        case .connectionRefused:
            "\(address) refused the connection. Check that remote desktop is turned on and the port is correct."
        case .localNetworkDenied:
            "macOS reported that Remora cannot access \(address) on the local network."
        case .connectionTimedOut:
            "\(address) didn’t respond. Check that the computer is turned on and reachable."
        case .serverEndedSession(let detail) where !detail.isEmpty:
            detail
        case .protocolError(let detail) where !detail.isEmpty:
            detail
        case .cancelledByUser:
            "You disconnected from “\(computerName)”."
        case .serverEndedSession, .protocolError, nil:
            "The remote computer ended the session."
        }
    }
}

/// Explains why system shortcuts stay on this Mac and links to the Accessibility pane.
struct ShortcutPermissionBanner: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "command")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Send System Shortcuts to the Remote Computer")
                    .font(.headline)
                Text("Shortcuts like Command-Tab and Command-Space stay on this Mac until you allow Remora to control this Mac in Privacy & Security settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 440, alignment: .leading)
            HStack(spacing: 8) {
                Button("Not Now", action: onDismiss)
                    .accessibilityIdentifier("shortcutPermissionNotNow")
                Button("Open System Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("shortcutPermissionOpenSettings")
            }
            .fixedSize()
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// The short confirmation after a screenshot.
struct CaptureConfirmation: View {
    let message: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        Label(message, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("captureConfirmation")
    }
}

/// The dimmed last frame while the tab switches to another remote display, with a glass capsule at
/// its center. A failed switch offers Try Again; the tab menu still offers the other displays.
struct DisplaySwitchStatus: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            HStack(spacing: 8) {
                if retry == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(message)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let retry {
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .accessibilityIdentifier("displayRetry")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, retry == nil ? 16 : 5)
            .frame(height: 38)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message)
            .accessibilityIdentifier("displaySwitchStatus")
        }
    }
}

/// A full screen notice: a glass capsule at the top of the remote screen that names a change and offers its action.
struct SessionNoticeCapsule: View {
    let notice: SessionNotices.Notice
    let agent: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(notice.tint)
                .accessibilityHidden(true)
            Text(notice.message(agent: agent))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let title = notice.actionTitle {
                Group {
                    if notice == .recording {
                        Button(title, action: action).buttonStyle(.bordered)
                    } else {
                        Button(title, action: action)
                            .buttonStyle(.borderedProminent)
                            .tint(Color(nsColor: .systemBlue))
                    }
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .accessibilityIdentifier("sessionNoticeButton")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, notice.actionTitle == nil ? 16 : 5)
        .frame(height: 38)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.message(agent: agent))
        .accessibilityIdentifier("sessionNotice")
    }
}

extension SessionNotices.Notice {
    func message(agent: String) -> String {
        switch self {
        case .agentInControl: "\(agent) is in control"
        case .agentPaused: "You’re in control. \(agent) is paused."
        case .agentStopped: "\(agent) can no longer control this session."
        case .recording: "Recording"
        }
    }

    fileprivate var symbolName: String {
        switch self {
        case .agentInControl: "pointer.arrow.motionlines"
        case .agentPaused: "pointer.arrow.slash"
        case .agentStopped: "stop.circle"
        case .recording: "record.circle"
        }
    }

    fileprivate var tint: AnyShapeStyle {
        switch self {
        case .agentInControl: AnyShapeStyle(Color(nsColor: .systemBlue))
        case .recording: AnyShapeStyle(Color(nsColor: .systemRed))
        case .agentPaused, .agentStopped: AnyShapeStyle(.secondary)
        }
    }

    fileprivate var actionTitle: String? {
        switch self {
        case .agentInControl: "Take Over"
        case .agentPaused: "Resume"
        case .agentStopped: nil
        case .recording: "Stop"
        }
    }
}

/// The key press display on the same glass as SessionNoticeCapsule. `KeyPressPill` places every item,
/// so recordings, which draw their own rendition of the glass, match it.
struct KeyPressCapsule: View {
    let pill: KeyPressPill?

    var body: some View {
        if let pill {
            ZStack(alignment: .topLeading) {
                ForEach(Array(pill.items.enumerated()), id: \.offset) { _, item in
                    Text(item.text)
                        .font(.system(size: KeyPressPill.fontSize(item.kind) * pill.scale, weight: .semibold))
                        .foregroundStyle(item.kind == .count ? .secondary : .primary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: item.frame.width, height: item.frame.height)
                        .background { if item.kind == .key { Capsule().fill(.quaternary) } }
                        .offset(x: item.frame.minX, y: item.frame.minY)
                }
            }
            .frame(width: pill.size.width, height: pill.size.height, alignment: .topLeading)
            .glassEffect(.regular, in: .capsule)
            .accessibilityHidden(true)
        }
    }
}

extension SessionControl.State {
    /// The tab's help and accessibility text, or nil while no program has controlled the session.
    func agentStatus(_ agent: String) -> String? {
        switch self {
        case .idle: nil
        case .active: "\(agent) is in control"
        case .paused: "\(agent) is paused"
        case .stopped: "\(agent) can no longer control this session."
        }
    }
}
