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
    /// FreeRDP's reconnect loop in the bridge stops after this many attempts.
    static let reconnectAttemptLimit = 20

    let status: SessionStatus
    let computerName: String
    let address: String
    var overDesktop = false
    var onCancel: () -> Void = {}
    var onReconnect: () -> Void = {}
    var onClose: () -> Void = {}

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
        VStack(spacing: 14) {
            header
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)
            actions
                .controlSize(.large)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var header: some View {
        switch status {
        case .connecting, .reconnecting:
            ProgressView()
                .controlSize(.large)
                .frame(height: 48)
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
            .font(.system(size: 40, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(height: 48)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var actions: some View {
        switch status {
        case .connecting, .reconnecting:
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
        case .awaitingCredentials, .awaitingTrust:
            EmptyView()
        case .disconnected:
            HStack(spacing: 12) {
                Button("Close", action: onClose)
                Button("Reconnect", action: onReconnect)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var title: String {
        switch status {
        case .connecting: "Connecting to “\(computerName)”"
        case .awaitingCredentials: "Waiting for Credentials"
        case .awaitingTrust: "Waiting for Certificate Approval"
        case .reconnecting: "Reconnecting to “\(computerName)”"
        case .disconnected(let reason): Self.title(for: reason)
        }
    }

    private var message: String {
        switch status {
        case .connecting: address
        case .awaitingCredentials: "Enter a username and password to connect to \(address)."
        case .awaitingTrust: "Review the certificate for \(address) to continue."
        case .reconnecting(let attempt): "Attempt \(attempt) of \(Self.reconnectAttemptLimit)"
        case .disconnected(let reason): message(for: reason)
        }
    }

    private static func symbolName(for reason: DisconnectReason?) -> String {
        switch reason {
        case .authenticationFailed: "person.crop.circle.badge.exclamationmark"
        case .certificateRejected: "lock.trianglebadge.exclamationmark"
        case .hostNotFound, .connectionRefused: "network.slash"
        case .connectionTimedOut: "clock.badge.exclamationmark"
        case .protocolError: "exclamationmark.triangle"
        case .serverEndedSession, .cancelledByUser, nil: "display"
        }
    }

    private static func title(for reason: DisconnectReason?) -> String {
        switch reason {
        case .authenticationFailed: "Authentication Failed"
        case .certificateRejected: "Certificate Not Trusted"
        case .hostNotFound: "Computer Not Found"
        case .connectionRefused: "Connection Refused"
        case .connectionTimedOut: "Connection Timed Out"
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
                Button("Open System Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
