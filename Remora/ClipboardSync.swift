import AppKit
import RemoraCore
import os

private let clipboardLog = Logger(subsystem: "com.peblon.remora", category: "Clipboard")

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
        sendLocalItemIfChanged()
    }

    func receiveRemoteItem(_ flavors: [RemoteClipboard.Flavor]) {
        guard canSync() else { return }
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        for flavor in flavors {
            item.setData(flavor.data, forType: .init(flavor.format.rawValue))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        changeCount = pasteboard.changeCount
    }

    private func sendLocalItemIfChanged() {
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
            // the pasteboard has no supported format. Further focus changes must not nag.
            guard !attemptedPrompt else { return }
            attemptedPrompt = true
        case .alwaysAllow:
            break
        @unknown default:
            return
        }
        changeCount = pasteboard.changeCount
        let formats = session.clipboardFormats
        if formats == [.text] {
            if let text = pasteboard.string(forType: .string) { session.setLocalClipboard(text: text) }
            return
        }
        for item in pasteboard.pasteboardItems ?? [] {
            let flavors = item.types.compactMap { type -> RemoteClipboard.Flavor? in
                guard let format = RemoteClipboard.Format(rawValue: type.rawValue), formats.contains(format),
                    let data = item.data(forType: type), !data.isEmpty || format == .text
                else { return nil }
                return .init(format, data)
            }
            if !flavors.isEmpty {
                session.setLocalClipboard(flavors: flavors)
                return
            }
        }
    }
}
