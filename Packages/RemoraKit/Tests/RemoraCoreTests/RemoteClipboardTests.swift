import RemoraCore
import Testing

@Test func remoteClipboardInvalidatesOldTextAndRejectsLateResponses() {
    var clipboard = RemoteClipboard()
    clipboard.update(revision: 1, status: .text("old"))
    clipboard.update(revision: 3, status: .pending)
    let accepted = clipboard.update(revision: 2, status: .text("late"))
    #expect(!accepted)
    #expect(clipboard.status == .pending)
    clipboard.update(revision: 4, status: .unavailable)
    #expect(clipboard.status == .unavailable)
    clipboard.update(revision: 5, status: .text(""))
    #expect(clipboard.status == .text(""))
    clipboard.update(revision: 6, status: .notReady)
    #expect(clipboard.status == .notReady)
}
