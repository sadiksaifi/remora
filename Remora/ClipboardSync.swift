import AppKit
import RemoraCore
import os

private let clipboardLog = Logger(subsystem: "dev.sadiksaifi.Remora", category: "Clipboard")

/// One instance per session attempt. The window forwards focus and session events.
@MainActor
final class ClipboardSync {
    private let session: any RemoteSession
    private var changeCount: Int?
    private var attemptedPrompt = false
    private var connected = false
    private let canSync: () -> Bool

    init(session: any RemoteSession, canSync: @escaping () -> Bool) {
        self.session = session
        self.canSync = canSync
    }

    func sessionDidConnect() {
        connected = true
    }

    func focusGained() {
        sendLocalTextIfChanged()
    }

    func receiveRemoteText(_ text: String) {
        guard canSync() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCount = pasteboard.changeCount
    }

    private func sendLocalTextIfChanged() {
        guard connected, canSync() else { return }
        let pasteboard = NSPasteboard.general
        guard changeCount != pasteboard.changeCount else { return }
        let access = pasteboard.accessBehavior
        clipboardLog.info("Pasteboard access behavior: \(String(describing: access), privacy: .public)")
        switch access {
        case .alwaysDeny:
            return
        case .default, .ask:
            // One potentially prompting read per session attempt, including when
            // access returns no string. Further focus changes must not nag.
            guard !attemptedPrompt else { return }
            attemptedPrompt = true
        case .alwaysAllow:
            break
        @unknown default:
            return
        }
        changeCount = pasteboard.changeCount
        if let text = pasteboard.string(forType: .string) {
            session.setLocalClipboard(text: text)
        }
    }
}
