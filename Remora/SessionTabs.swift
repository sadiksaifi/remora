import AppKit
import Observation
import RemoraCore
import RemoraControl

/// The open session tabs of the main window, at most one per connection, and which page the window shows:
/// the connections list (home) or one tab. Views observe it; the main window shows the selected page.
@MainActor @Observable
final class SessionTabs {
    struct Tab: Identifiable, Equatable {
        /// The connection ID.
        let id: UUID
        var title: String
        var state: SessionState
        /// A credentials or certificate request waits until the tab shows.
        var needsAttention = false
        /// The tab's desktop has the keyboard of the active key window.
        var isKeyboardCaptured = false
    }

    @ObservationIgnored var onControlEvent: ((String, SessionViewController, ControlValue?) -> Void)?
    private(set) var tabs: [Tab] = []
    /// The shown tab, or nil while the connections list shows.
    private(set) var selection: UUID?
    /// Called synchronously after the selection changes, so the window shows the page before a session starts.
    @ObservationIgnored var onSelectionChange: ((_ old: UUID?, _ new: UUID?) -> Void)?
    @ObservationIgnored private var sessions: [UUID: SessionViewController] = [:]
    @ObservationIgnored private var closingCaptures: [UUID: SessionCapture] = [:]
    @ObservationIgnored private let connectionStore: ConnectionStore
    @ObservationIgnored private(set) var resolvedPrompts: [UUID] = []
    @ObservationIgnored private let credentialStore: CredentialStore

    init(connectionStore: ConnectionStore, credentialStore: CredentialStore) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
    }

    /// The session state of each open tab, keyed by connection ID. A connection without a tab has no entry.
    var states: [UUID: SessionState] {
        Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.state) })
    }

    var liveCount: Int {
        tabs.count { $0.state.isLive }
    }

    var selectedSession: SessionViewController? {
        selection.flatMap { sessions[$0] }
    }

    func session(for id: UUID) -> SessionViewController? {
        sessions[id]
    }

    /// Opens or reuses a tab. Background callers leave selection unchanged. Ended tabs reconnect in place.
    /// Returns true when it started a new session.
    @discardableResult
    func open(_ connection: Connection, select shouldSelect: Bool = true, commandLine: Bool = false, resolution: ConnectionResolution? = nil) -> Bool {
        let id = connection.id
        if let existing = sessions[id] {
            if shouldSelect { select(id) }
            guard !existing.state.isLive else { return false }
            existing.update(connection)
            existing.configureCommandLine(commandLine, resolution: resolution)
            existing.start()
            return true
        }
        let session = SessionViewController(
            connection: connection, credentialStore: credentialStore,
            onStateChange: { [weak self] state in self?.update(id) { $0.state = state } },
            onAttentionChange: { [weak self] attention in self?.update(id) { $0.needsAttention = attention } },
            onKeyboardCaptureChange: { [weak self] captured in self?.update(id) { $0.isKeyboardCaptured = captured } },
            onClose: { [weak self] in self?.close(id) },
            onPromptResolved: { [weak self] prompt in
                guard let self else { return }
                resolvedPrompts.append(prompt)
                if resolvedPrompts.count > 64 { resolvedPrompts.removeFirst() }
            },
            onRememberCredentials: { [weak self] credentials in
                guard let self,
                      let current = connectionStore.connections.first(where: { $0.id == id }) else {
                    throw ControlFailure(.notFound, "The saved connection was deleted.")
                }
                let updated = try ConnectionPatch(username: credentials.username, domain: credentials.domain).applying(to: current)
                do { try connectionStore.update(updated) }
                catch { throw ControlFailure(.storeFailed, "Could not save account metadata.") }
                self.update(updated)
                do {
                    if credentials.password.isEmpty { try credentialStore.removePassword(for: id) }
                    else { try credentialStore.setPassword(credentials.password, for: id) }
                } catch { throw ControlFailure(.credentialFailed, "Account metadata was saved, but the password operation failed.", details: .object(["recordSaved": .bool(true)])) }
            }
        )
        sessions[id] = session
        tabs.append(Tab(id: id, title: connection.name, state: session.state))
        if shouldSelect { select(id) }
        session.configureCommandLine(commandLine, resolution: resolution)
        session.start()
        session.onControlEvent = { [weak self, weak session] type, data in
            guard let session else { return }
            self?.onControlEvent?(type, session, data)
        }
        onControlEvent?("session.state", session, nil)
        return true
    }

    /// Renames the connection's tab after an edit. Its session uses the saved settings from the next
    /// connection attempt on.
    func update(_ connection: Connection) {
        guard let session = sessions[connection.id] else { return }
        session.update(connection)
        update(connection.id) { $0.title = connection.name }
    }

    /// Shows the tab, or the connections list for nil.
    func select(_ id: UUID?) {
        guard id != selection, id.map({ sessions[$0] != nil }) ?? true else { return }
        let old = selection
        selection = id
        onSelectionChange?(old, id)
    }

    /// Shows the tab at the zero-based index.
    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    /// Moves to the next or previous tab, wrapping around. From the connections list it moves to the first or last tab.
    func selectAdjacent(forward: Bool) {
        guard !tabs.isEmpty else { return }
        let current = selection.flatMap { id in tabs.firstIndex { $0.id == id } }
        let index = current.map { ($0 + (forward ? 1 : -1) + tabs.count) % tabs.count }
            ?? (forward ? 0 : tabs.count - 1)
        select(tabs[index].id)
    }

    /// Disconnects the session without asking and removes its tab. A shown tab gives way to its right
    /// neighbor, then its left neighbor, then the connections list.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if selection == id {
            let neighbor = tabs.indices.contains(index + 1) ? tabs[index + 1].id : index > 0 ? tabs[index - 1].id : nil
            select(neighbor)
        }
        if let session = sessions.removeValue(forKey: id) {
            let capture = session.capture
            let token = UUID()
            closingCaptures[token] = capture
            session.close()
            onControlEvent?("session.state", session, .object(["session": .string(session.attemptID.uuidString), "state": .string("closed")]))
            Task { [self] in
                await capture.stopRecording()
                closingCaptures[token] = nil
            }
        }
        tabs.remove(at: index)
    }

    /// Ends the connection's session the way Session > Disconnect does. The tab stays open.
    func disconnect(_ id: UUID) {
        sessions[id]?.disconnectSession()
    }

    /// True while any open tab records or finishes a recording.
    var isRecording: Bool {
        sessions.values.contains {
            switch $0.capture.recordingState {
            case .recording, .finishing: true
            case .idle, .failed: false
            }
        }
    }

    var unfinishedCaptureURLs: [URL] {
        (sessions.values.map(\.capture) + Array(closingCaptures.values)).compactMap(\.recordingURL)
    }

    /// Disconnects sessions and finishes recordings, including those from closed tabs.
    @discardableResult
    func prepareToQuit() async -> [CaptureFailure] {
        let captures = (sessions.values.map(\.capture) + Array(closingCaptures.values)).filter {
            switch $0.recordingState {
            case .recording, .finishing: true
            case .idle, .failed: false
            }
        }
        for session in sessions.values { session.disconnect() }
        return await withTaskGroup(of: CaptureFailure?.self) { group in
            for capture in captures {
                group.addTask {
                    _ = await capture.stopRecording()
                    if case .failed(let failure) = await capture.recordingState { return failure }
                    return nil
                }
            }
            var failures: [CaptureFailure] = []
            for await failure in group { if let failure { failures.append(failure) } }
            return failures
        }
    }

    private func update(_ id: UUID, _ change: (inout Tab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[index])
    }
}

extension SessionState {
    /// True until the session ends. A live session can be disconnected; an ended one reconnects.
    var isLive: Bool {
        if case .disconnected = self { false } else { true }
    }

    /// The status dot color in the connections list and the tab strip.
    var statusColor: NSColor {
        switch self {
        case .connected: .systemGreen
        case .connecting, .awaitingCredentials, .awaitingTrust, .reconnecting: .systemOrange
        case .disconnected: .systemGray
        }
    }

    var statusTitle: String {
        switch self {
        case .connecting: "Connecting…"
        case .awaitingCredentials: "Waiting for Credentials"
        case .awaitingTrust: "Waiting for Approval"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .disconnected: "Disconnected"
        }
    }
}
