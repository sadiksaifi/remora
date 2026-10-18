import AppKit
import RDPSession
import RemoraCore
import SwiftUI
import os

private let sessionLog = Logger(subsystem: "dev.sadiksaifi.Remora", category: "Session")

/// One tab's page. Owns a single-use session per attempt. Closing cancels both the stream and any sheet.
/// Sheets attach to the main window only while the tab shows; a hidden tab's request waits and marks the tab.
@MainActor
final class SessionViewController: NSViewController {
    private(set) var connection: Connection
    private let credentialStore: CredentialStore
    private let onStateChange: (SessionState) -> Void
    private let onAttentionChange: (Bool) -> Void
    private let onKeyboardCaptureChange: (Bool) -> Void
    private let onClose: () -> Void
    private var session: (any RemoteSession)?
    private var clipboardSync: ClipboardSync?
    private var overlays: SessionOverlays?
    private weak var desktopView: RemoteDesktopView?
    private var eventTask: Task<Void, Never>?
    private var sheet: NSWindow?
    private var cancelChallenge: (() -> Void)?
    /// Presents the waiting credentials or certificate sheet once the tab shows.
    private var pendingSheet: ((NSWindow) -> Void)?
    /// A capture failure waits separately, so it never replaces a credentials or certificate request.
    private var pendingAlert: NSAlert?
    private var credentials: SessionCredentials?
    /// The state the tab shows. Setup failures and teardown count as disconnected.
    private(set) var state: SessionState = .connecting {
        didSet {
            if state != oldValue { onStateChange(state) }
            updateDesktopAccessibility()
        }
    }
    private let container = SessionContainerView()
    /// The status view or the desktop, filling the container.
    private var content: NSView?
    private var statusView: NSHostingView<SessionStatusView>?
    private var closed = false
    private let display: SessionDisplay
    let capture = SessionCapture(media: AppleCaptureMedia(), destination: ScreenshotDestination { AppSettings.saveFolder })

    init(
        connection: Connection, credentialStore: CredentialStore,
        onStateChange: @escaping (SessionState) -> Void,
        onAttentionChange: @escaping (Bool) -> Void,
        onKeyboardCaptureChange: @escaping (Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.credentialStore = credentialStore
        self.onStateChange = onStateChange
        self.onAttentionChange = onAttentionChange
        self.onKeyboardCaptureChange = onKeyboardCaptureChange
        self.onClose = onClose
        display = SessionDisplay(view: container)
        super.init(nibName: nil, bundle: nil)
        capture.onRecordingActivityChange = { [weak self] active in
            self?.display.setRecording(active)
            self?.updateDesktopAccessibility()
            if !active { self?.reportRecordingResult() }
        }
        container.onResize = { [weak self] in self?.display.requestResize() }
        container.onVisibilityChange = { [weak self] in self?.display.visibilityChanged() }
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connection:credentialStore:onStateChange:onAttentionChange:onKeyboardCaptureChange:onClose:)")
    }

    isolated deinit {
        eventTask?.cancel()
        session?.disconnect()
        cancelChallenge?()
        sessionLog.info("Session released")
    }

    override func loadView() {
        view = container
    }

    /// Starts the first session. Call after the tab shows, so Fit to Window can measure the content area.
    func start() {
        startSession()
    }

    func reconnect() {
        startSession()
    }

    /// Takes the saved connection after an edit. A running session keeps its settings; the next
    /// attempt uses the new ones and reads the password from the Keychain again.
    func update(_ connection: Connection) {
        self.connection = connection
        credentials = nil
        desktopView?.accessibilityTab = (connection.id, connection.name)
    }

    /// Ends the session and removes the tab's views. The tab can't reconnect afterwards.
    func close() {
        closed = true
        disconnect()
        view.removeFromSuperview()
        removeFromParent()
    }

    func disconnect() {
        finishCapture()
        capture.setSource(nil)
        state = .disconnected(nil)
        desktopView?.setSessionConnected(false)
        overlays = nil
        desktopView = nil
        clipboardSync = nil
        display.disconnect()
        session?.disconnect()
        session = nil
        eventTask?.cancel()
        eventTask = nil
        dismissChallenge()
        // Removing the desktop stops its display link as well.
        content?.removeFromSuperview()
        content = nil
    }

    // MARK: Showing and hiding

    /// Called after the tab's view joins the window. The desktop redraws and takes the keyboard on its own.
    func didShow() {
        presentPendingSheet()
        display.requestResize()
        focusStatus()
    }

    /// Gives the keyboard back to a connected desktop, for example after the search field closes.
    func focusDesktop() {
        guard state == .connected, let desktopView, let window = view.window else { return }
        window.makeFirstResponder(desktopView)
    }

    func windowWillTransition() { display.willTransition() }
    func windowDidTransition() { display.didTransition() }
    func windowDidChangeSize() { display.requestResize() }

    // MARK: Session menu

    var canDisconnect: Bool { session != nil }
    var canReconnect: Bool { session == nil && !closed }
    var isConnected: Bool { state == .connected }
    var hasKeyboard: Bool { state == .connected && view.window?.firstResponder === desktopView }

    func disconnectSession() {
        finishCapture()
        session?.disconnect()
    }

    private func finishCapture() {
        let capture = capture
        Task { await capture.stopRecording() }
    }

    /// Every stop path, including an encoder failure, ends here. Stop callers share one finish result.
    private func reportRecordingResult() {
        let capture = capture
        Task { [weak self] in
            let result = await capture.stopRecording()
            self?.updateDesktopAccessibility()
            guard case .failure(let failure) = result else { return }
            sessionLog.error("Capture: \(failure.localizedDescription, privacy: .public)")
            self?.presentCaptureFailure(failure)
        }
    }

    /// Saves or copies a screenshot of the desktop, with a short confirmation or a failure sheet.
    func captureScreenshot(copyToClipboard: Bool) {
        Task {
            do {
                _ = try await takeScreenshot(copyToClipboard: copyToClipboard)
                overlays?.confirm(copyToClipboard ? "Screenshot Copied" : "Screenshot Saved")
            } catch {
                presentCaptureFailure(error as? CaptureFailure ?? .image(error.localizedDescription))
            }
        }
    }

    /// Starts a recording, or stops the one in progress. A finishing recording ignores the request.
    func toggleRecording() {
        switch capture.recordingState {
        case .recording:
            Task { await stopRecording() }
        case .finishing:
            break
        case .idle, .failed:
            do { try startRecording() } catch {
                presentCaptureFailure(error as? CaptureFailure ?? .recording(error.localizedDescription))
            }
        }
    }

    /// The failure's description already names any capture file that cleanup could not remove.
    /// A hidden tab marks itself and shows the sheet when it shows.
    private func presentCaptureFailure(_ failure: CaptureFailure) {
        guard !closed else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Capture Failed"
        alert.informativeText = failure.localizedDescription
        pendingAlert = alert
        presentPendingSheet()
    }

    func takeScreenshot(copyToClipboard: Bool = false) async throws -> URL? {
        if copyToClipboard {
            let png = try await capture.screenshotPNG()
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setData(png, forType: .png) else {
                throw CaptureFailure.image("Could not write to the clipboard.")
            }
            return nil
        }
        return try await capture.saveScreenshot(connectionName: connection.name)
    }

    func startRecording() throws { try capture.startRecording(connectionName: connection.name) }

    @discardableResult
    func stopRecording() async -> Result<URL, CaptureFailure>? { await capture.stopRecording() }

    func sendCtrlAltDelete() { desktopView?.sendCtrlAltDelete() }

    func releaseKeyboardCapture() {
        guard let window = view.window, window.firstResponder === desktopView else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: Session

    private func startSession() {
        guard !closed else { return }
        disconnect()
        state = .connecting
        let connectingView = showStatus(.connecting)
        do {
            guard let port = UInt16(exactly: connection.port), port > 0 else {
                fail(.protocolError("The connection port must be between 1 and 65535."))
                return
            }
            guard connection.resolution.isValid else {
                fail(.protocolError("The resolution must be 200 to 8192 pixels per side with an even width."))
                return
            }
            let currentCredentials: SessionCredentials
            if let credentials {
                currentCredentials = credentials
            } else {
                currentCredentials = SessionCredentials(
                    username: connection.username, domain: connection.domain ?? "",
                    password: try credentialStore.password(for: connection.id) ?? ""
                )
                credentials = currentCredentials
            }
            let renderer = try FrameRenderer()
            view.window?.contentView?.layoutSubtreeIfNeeded()
            let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let points = connectingView.bounds.size
            let desktopSize: DesktopSize
            let scaleFactor: Double
            let allowsDynamicResize: Bool
            switch connection.resolution {
            case .fitToWindow:
                // A tab always shows before it starts. The fallback covers a content area that has no size yet.
                desktopSize = points.width > 0 && points.height > 0
                    ? DesktopSize(width: Int(points.width * backingScale), height: Int(points.height * backingScale))
                    : DesktopSize(width: 1920, height: 1080)
                scaleFactor = backingScale
                allowsDynamicResize = true
            case .fixed(let width, let height):
                desktopSize = DesktopSize(width: width, height: height)
                scaleFactor = 1
                allowsDynamicResize = false
            }
            sessionLog.info("Requested desktop: \(desktopSize.width)x\(desktopSize.height), scale=\(scaleFactor), dynamic=\(allowsDynamicResize)")
            let configuration = SessionConfiguration(
                host: connection.host, port: port, username: currentCredentials.username,
                domain: currentCredentials.domain,
                password: currentCredentials.password.isEmpty ? nil : currentCredentials.password,
                desktopSize: desktopSize, scaleFactor: scaleFactor, allowsDynamicResize: allowsDynamicResize
            )
            capture.setSource(renderer.desktop)
            let session = RDPSession(configuration: configuration, frameSink: renderer)
            let desktopView = RemoteDesktopView(renderer: renderer)
            desktopView.input = session
            self.desktopView = desktopView
            overlays = SessionOverlays(
                desktop: desktopView, computerName: connection.name, address: connection.displayAddress
            ) { [weak session] in session?.disconnect() }
            self.session = session
            clipboardSync = ClipboardSync(session: session)
            desktopView.onFocus = { [weak self] in self?.clipboardSync?.focusGained() }
            desktopView.accessibilityTab = (connection.id, connection.name)
            desktopView.onCaptureChange = { [weak self, weak desktopView] captured in
                desktopView?.isKeyboardCaptured = captured
                self?.updateDesktopAccessibility()
                self?.onKeyboardCaptureChange(captured)
            }
            desktopView.onAccessibilityCapture = { [weak self] capture in
                if capture { self?.focusDesktop() } else { self?.releaseKeyboardCapture() }
            }
            display.attach(session)
            let events = session.events
            eventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { break }
                    self?.receive(event, desktopView: desktopView)
                }
            }
            session.connect()
        } catch {
            sessionLog.error("Session setup failed: \(error.localizedDescription, privacy: .public)")
            fail(.protocolError(error.localizedDescription))
        }
    }

    /// Shows a session that ended before it started.
    private func fail(_ reason: DisconnectReason) {
        state = .disconnected(reason)
        showStatus(.disconnected(reason))
    }

    private func receive(_ event: SessionEvent, desktopView: RemoteDesktopView) {
        guard !closed else { return }
        switch event {
        case .stateChanged(let state):
            sessionLog.info("State: \(String(describing: state), privacy: .public)")
            let previous = self.state
            self.state = state
            switch state {
            case .connecting:
                if content !== desktopView { showStatus(.connecting) }
            case .awaitingCredentials:
                if content !== desktopView { showStatus(.awaitingCredentials) }
            case .awaitingTrust:
                if content !== desktopView { showStatus(.awaitingTrust) }
            case .connected:
                clipboardSync?.sessionDidConnect()
                dismissChallenge()
                setContent(desktopView)
                if case .reconnecting = previous { announce("Reconnected to “\(connection.name)”") }
                overlays?.connected()
                // Leave the keyboard with the search field while the user types in it.
                if let window = view.window, (window.firstResponder as? NSTextView)?.isFieldEditor != true {
                    window.makeFirstResponder(desktopView)
                }
                display.didConnect()
                desktopView.setSessionConnected(true)
            case .reconnecting(let attempt):
                desktopView.setSessionConnected(false)
                if let window = view.window, window.firstResponder === desktopView {
                    window.makeFirstResponder(nil)
                }
                if case .reconnecting = previous {} else {
                    announce("Reconnecting to “\(connection.name)”, attempt \(attempt) of \(SessionStatusView.reconnectAttemptLimit)")
                }
                overlays?.reconnecting(attempt: attempt)
            case .disconnected(let reason):
                finishCapture()
                capture.setSource(nil)
                desktopView.setSessionConnected(false)
                overlays = nil
                clipboardSync = nil
                dismissChallenge()
                session = nil
                display.disconnect()
                showStatus(.disconnected(reason))
                announce(SessionStatusView.title(for: reason))
            }
        case .remoteClipboardText(let text):
            clipboardSync?.receiveRemoteText(text)
        case .desktopSizeChanged(let size, _):
            // The window never resizes for a session. The renderer aspect-fits any desktop size.
            sessionLog.info("Desktop size: \(size.width)x\(size.height)")
        case .dynamicResizeChanged(let available):
            if available { display.requestResize() }
        case .cursorChanged(let cursor):
            desktopView.apply(cursor: cursor)
        case .credentialsChallenge(let challenge):
            dismissChallenge()
            cancelChallenge = { challenge.responder.respond(nil) }
            presentWhenShown { [weak self] window in self?.showCredentials(challenge, on: window) }
        case .trustChallenge(let challenge):
            dismissChallenge()
            cancelChallenge = { challenge.responder.respond(.reject) }
            presentWhenShown { [weak self] window in self?.showTrust(challenge, on: window) }
        }
    }

    // MARK: Sheets

    private func presentWhenShown(_ present: @escaping (NSWindow) -> Void) {
        pendingSheet = present
        presentPendingSheet()
    }

    /// AppKit queues a second sheet until the first one ends.
    private func presentPendingSheet() {
        guard pendingSheet != nil || pendingAlert != nil else { return }
        guard let window = view.window else {
            onAttentionChange(true)
            return
        }
        onAttentionChange(false)
        if let present = pendingSheet {
            pendingSheet = nil
            present(window)
        }
        if let alert = pendingAlert {
            pendingAlert = nil
            alert.beginSheetModal(for: window)
        }
    }

    private func showCredentials(_ challenge: CredentialsChallenge, on window: NSWindow) {
        let form = SessionCredentialsView(
            challenge: challenge, computerName: connection.name, address: connection.displayAddress,
            password: credentials?.password ?? "",
            onCancel: { [weak self] in self?.dismissChallenge() },
            onConnect: { [weak self] answer, remember in
                guard let self else { challenge.responder.respond(nil); return }
                if remember {
                    do {
                        try credentialStore.setPassword(answer.password, for: connection.id)
                    } catch {
                        NSApplication.shared.presentError(error, modalFor: self.sheet ?? window, delegate: nil,
                                                          didPresent: nil, contextInfo: nil)
                        return
                    }
                }
                credentials = answer
                cancelChallenge = nil
                dismissChallenge()
                challenge.responder.respond(answer)
            }
        )
        let controller = NSHostingController(rootView: form)
        controller.sizingOptions = .preferredContentSize
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Credentials"
        self.sheet = sheet
        window.beginSheet(sheet)
    }

    private func showTrust(_ challenge: TrustChallenge, on window: NSWindow) {
        let address = challenge.port == UInt16(Connection.defaultPort)
            ? challenge.host : "\(challenge.host):\(challenge.port)"
        let alert = NSAlert()
        var details = [("Subject", challenge.subject), ("Issuer", challenge.issuer), ("SHA-256", challenge.fingerprint)]
        let connectButton: NSApplication.ModalResponse
        if case .changed(let oldFingerprint) = challenge.status {
            alert.alertStyle = .critical
            alert.messageText = "The certificate for “\(address)” has changed."
            alert.informativeText = "Someone might be impersonating this computer. Connect only if you know its certificate was replaced."
            details.append(("Previous SHA-256", oldFingerprint))
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Connect Anyway").hasDestructiveAction = true
            connectButton = .alertSecondButtonReturn
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Remora can’t verify the identity of “\(address)”."
            alert.informativeText = "Connect only if this certificate belongs to the computer you expect. Remora remembers it after you connect."
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            connectButton = .alertFirstButtonReturn
        }
        alert.accessoryView = Self.certificateDetails(details)
        let certificateSheet = alert.window
        sheet = certificateSheet
        alert.beginSheetModal(for: window) { [weak self, weak certificateSheet] response in
            challenge.responder.respond(response == connectButton ? .trust : .reject)
            guard let self, sheet === certificateSheet else { return }
            cancelChallenge = nil
            sheet = nil
        }
    }

    /// Labeled, selectable certificate fields for the trust alert.
    private static func certificateDetails(_ rows: [(String, String)]) -> NSView {
        let width: CGFloat = 300
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (label, value) in rows {
            let title = NSTextField(labelWithString: label)
            title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            title.textColor = .secondaryLabelColor
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = label.hasSuffix("SHA-256")
                ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.lineBreakMode = .byCharWrapping
            field.isSelectable = true
            field.preferredMaxLayoutWidth = width
            let group = NSStackView(views: [title, field])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 2
            stack.addArrangedSubview(group)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = stack.fittingSize
        return stack
    }

    /// Cancels a waiting or shown credentials or certificate request.
    private func dismissChallenge() {
        let cancel = cancelChallenge
        cancelChallenge = nil
        cancel?()
        if pendingSheet != nil {
            pendingSheet = nil
            onAttentionChange(pendingAlert != nil)
        }
        if let sheet {
            self.sheet = nil
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
            sheet.contentViewController = nil
        }
    }

    // MARK: Content

    private func setContent(_ newContent: NSView) {
        guard newContent !== content else { return }
        content?.removeFromSuperview()
        newContent.frame = container.bounds
        newContent.autoresizingMask = [.width, .height]
        container.addSubview(newContent)
        content = newContent
    }

    /// Replaces the tab's content with a status view, removing any desktop.
    @discardableResult
    private func showStatus(_ status: SessionStatus) -> NSView {
        var rootView = SessionStatusView(
            status: status, computerName: connection.name, address: connection.displayAddress,
            onCancel: { [weak self] in self?.session?.disconnect() },
            onReconnect: { [weak self] in self?.startSession() },
            onClose: { [weak self] in self?.onClose() }
        )
        // Leave the keyboard with the search field while the user types in it.
        rootView.focusesClose = (view.window?.firstResponder as? NSTextView)?.isFieldEditor != true
        if let statusView, content === statusView {
            statusView.rootView = rootView
            return statusView
        }
        let view = NSHostingView(rootView: rootView)
        view.sizingOptions = []
        setContent(view)
        statusView = view
        focusStatus()
        return view
    }

    /// Moves the keyboard into a shown status view once the desktop leaves, so Tab reaches its buttons.
    /// Leaves it with a search field or any other view that still has it.
    private func focusStatus() {
        guard let statusView, content === statusView, let window = view.window else { return }
        if let responder = window.firstResponder as? NSView, responder.window === window { return }
        window.makeFirstResponder(statusView)
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The desktop's accessibility value: session status, keyboard capture, and recording.
    private func updateDesktopAccessibility() {
        guard let desktopView else { return }
        var parts = [String]()
        if case .reconnecting(let attempt) = state {
            parts.append("Reconnecting, attempt \(attempt) of \(SessionStatusView.reconnectAttemptLimit)")
        } else {
            parts.append(state.statusTitle)
        }
        parts.append(desktopView.isKeyboardCaptured ? "keyboard captured" : "keyboard released")
        switch capture.recordingState {
        case .recording: parts.append("recording")
        case .finishing: parts.append("finishing recording")
        case .idle, .failed: break
        }
        desktopView.accessibilityState = parts.joined(separator: ", ")
    }
}

/// The session's content area below the toolbar. Fit to Window follows its size and backing scale.
/// It reports joining or leaving the window and the window's occlusion changes.
@MainActor
private final class SessionContainerView: NSView {
    var onResize: (() -> Void)?
    var onVisibilityChange: (() -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidChangeOcclusionState(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
        }
        onVisibilityChange?()
    }

    @objc private func windowDidChangeOcclusionState(_ notification: Notification) {
        onVisibilityChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?()
    }
}
