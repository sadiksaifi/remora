import AppKit
import RemoraCore

/// One instance per session attempt. The window forwards focus and session events.
@MainActor
final class ClipboardSync {
    private let session: any RemoteSession
    private var changeCount: Int?
    private var attemptedPrompt = false
    private var connected = false

    init(session: any RemoteSession) {
        self.session = session
    }

    func sessionDidConnect() {
        connected = true
        sendLocalTextIfChanged()
    }

    func windowDidBecomeKey() {
        sendLocalTextIfChanged()
    }

    func applicationDidBecomeActive(isSessionWindowKey: Bool) {
        if isSessionWindowKey { sendLocalTextIfChanged() }
    }

    func receiveRemoteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changeCount = pasteboard.changeCount
    }

    private func sendLocalTextIfChanged() {
        guard connected else { return }
        let pasteboard = NSPasteboard.general
        guard changeCount != pasteboard.changeCount else { return }
        switch pasteboard.accessBehavior {
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
