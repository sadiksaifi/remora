import AppKit
import RDPSession
import RemoraControl
import RemoraCore
import SwiftUI
import VNCSession
import os

private let sessionLog = Logger(subsystem: "com.peblon.remora", category: "Session")

/// One tab's page. Owns a single-use session per attempt. Closing cancels both the stream and any sheet.
/// Sheets attach to the main window only while the tab shows; a hidden tab's request waits and marks the tab.
@MainActor
final class SessionViewController: NSViewController {
    private(set) var connection: Connection
    private(set) var attemptConnection: Connection
    private let credentialStore: CredentialStore
    private let onStateChange: (SessionState) -> Void
    private let onAttentionChange: (Bool) -> Void
    private let onKeyboardCaptureChange: (Bool) -> Void
    private let onClose: () -> Void
    private let onPromptResolved: (UUID) -> Void
    private let onRememberCredentials: (SessionCredentials) throws -> Void
    var onControlEvent: ((String, ControlValue?) -> Void)?
    /// Receives the shown display's name, or nil while the remote reports at most one display.
    var onDisplayChange: ((String?) -> Void)?
    var inputGeometryRevision = 0
    private var frameBaseline = 0
    private var retiredFrameRevision = 0
    var frameRevision: Int { renderer.map { max(0, $0.desktop.revision - frameBaseline) } ?? retiredFrameRevision }
    private(set) var attemptID = UUID() {
        didSet {
            inputGeometryRevision += 1
            control.invalidateObservation()
            frameBaseline = renderer?.desktop.revision ?? 0
            retiredFrameRevision = 0
            desktopSeen = false
            onControlEvent?("session.replaced", .object(["previousSession": .string(oldValue.uuidString), "session": .string(attemptID.uuidString)]))
        }
    }
    /// A `connect` has waited out the black frames a server draws while it attaches this attempt.
    var desktopSeen = false
    /// "you", or the label of the command-line program that opened the tab.
    private(set) var startedBy = "you"
    /// The command-line program that last took control, for the capsule, tab and menus.
    private(set) var agentName = "remora CLI"
    private(set) var attemptResolution: ConnectionResolution?
    private var commandLine = false
    /// Follows human control ownership, independently of who opened the tab.
    var allowsMacClipboardSync = true {
        didSet {
            if allowsMacClipboardSync { clipboardSync?.focusGained() }
        }
    }
    private(set) var remoteClipboard = RemoteClipboard()

    private var canSyncMacClipboard: Bool {
        allowsMacClipboardSync && state == .connected && session?.supportsClipboardSynchronization == true && NSApp.isActive && view.window?.isKeyWindow == true
            && view.window?.isVisible == true && view.window?.isMiniaturized == false && view.window?.firstResponder === desktopView
    }

    func offerClipboardText(_ text: String, agent: String?) throws {
        guard state == .connected, let session else { throw ControlFailure(.notConnected, "The session is not connected.") }
        guard !text.utf8.contains(0) else { throw ControlFailure(.invalidArgument, "Clipboard text cannot contain NUL bytes.") }
        guard session.supportsClipboardSynchronization else { throw ControlFailure(.unsupported, "This session does not exchange clipboard text.") }
        try attachAgentControl(agent: agent)
        session.setLocalClipboard(text: text)
    }
    private var renderer: FrameRenderer?
    private(set) var desktopSize: DesktopSize?
    var frameSize: DesktopSize? { renderer?.desktop.size }
    var supportsDynamicResize: Bool { session?.supportsDynamicResize == true }
    enum Prompt {
        case credentials(UUID, CredentialsChallenge)
        case certificate(UUID, TrustChallenge)
        var id: UUID {
            switch self {
            case .credentials(let id, _), .certificate(let id, _): id
            }
        }
    }
    private(set) var pendingPrompt: Prompt? {
        didSet {
            if pendingPrompt != nil { onControlEvent?("prompt.opened", nil) }
        }
    }
    private(set) var credentialDraft: SessionCredentialDraft?

    /// A nil `agent` means a person opened the tab in Remora.
    func configureCommandLine(agent: String?, resolution: ConnectionResolution?) {
        commandLine = agent != nil
        startedBy = agent ?? "you"
        if let agent { agentName = agent }
        attemptResolution =
            commandLine ? resolution ?? (connection.resolution == .fitToWindow ? .fixed(width: 1920, height: 1080) : connection.resolution) : nil
    }

    func addFrameDemand() { display.addCommandLineDemand() }
    /// The server was paused and its redraw has not arrived yet.
    var awaitsRedraw: Bool { session?.awaitsRedraw == true }
    /// The frame shows the desktop as the server has it now.
    var hasFreshFrame: Bool { frameRevision > 0 && !awaitsRedraw && frameSize == desktopSize && displayIsReady }

    /// The remote displays and which one the tab shows. Empty when the remote reports none, as over RDP.
    private(set) var displays = SessionDisplays()
    /// False while a remote with displays switches, fails to switch, or has not shown one yet.
    var displayIsReady: Bool { displays.displays.isEmpty || displays.isReady }

    /// Shows one remote display, for the tab menu, the View menu and the command line. Until the new
    /// display's first frame, the session drops input and captures and agent observations expire.
    @discardableResult
    func selectDisplay(_ id: UInt32) -> Result<Void, DisplaySelectionFailure> {
        guard state == .connected, let session else { return .failure(.unavailable) }
        let result = session.selectDisplay(id)
        if case .success = result { applyDisplays(session.displays) }
        return result
    }

    /// The display left or right of the shown one in menu order, wrapping around.
    func selectAdjacentDisplay(forward: Bool) {
        let ordered = displays.ordered
        guard ordered.count > 1, displays.pendingID == nil,
            let index = ordered.firstIndex(where: { $0.id == displays.selectedID }) ?? (forward ? ordered.indices.last : ordered.indices.first)
        else { return }
        let next = ordered[(index + (forward ? 1 : ordered.count - 1)) % ordered.count]
        if case .failure = selectDisplay(next.id) { NSSound.beep() }
    }

    var canChooseDisplay: Bool { state == .connected && displays.displays.count > 1 && displays.pendingID == nil }

    private func applyDisplays(_ new: SessionDisplays) {
        let old = displays
        guard new != old else { return }
        displays = new
        if new.selectedID != old.selectedID || new.isReady != old.isReady {
            inputGeometryRevision += 1
            control.invalidateObservation()
        }
        // The first display after connecting is not a switch, so it shows no switching status or note.
        let switching = shownDisplay
        if new.isReady { shownDisplay = true }
        if let pending = new.pendingID, switching {
            overlays?.showDisplaySwitch(DisplaySwitchStatus(message: "Switching to \(new.name(of: pending) ?? "Display")…"), after: .milliseconds(150))
        } else if new.isReady {
            overlays?.showDisplaySwitch(nil)
            if switching, old.pendingID != nil, let note = displayNotice ?? new.name(of: new.selectedID) {
                overlays?.confirm(note, systemImage: "display", sound: false)
            }
            displayNotice = nil
        }
        onDisplayChange?(new.name(of: new.pendingID ?? new.selectedID))
        updateDesktopAccessibility()
        onControlEvent?("session.display", nil)
        // The remote dropped the shown display. Show another rather than keep a picture of nothing.
        if let gone = old.selectedID ?? old.pendingID, new.selectedID == nil, new.pendingID == nil,
            !new.displays.contains(where: { $0.id == gone })
        {
            showDefaultDisplay(after: "\(old.name(of: gone) ?? "The display") was disconnected.")
        }
    }

    /// Replaces the display name in the note that follows the next completed switch.
    private var displayNotice: String?
    /// This attempt has shown a remote display.
    private var shownDisplay = false

    private func showDefaultDisplay(after notice: String) {
        guard let id = displays.defaultID else { return }
        displayNotice = notice
        if case .failure = selectDisplay(id) { displayNotice = nil }
    }

    private func displaySelectionFailed(_ id: UInt32, _ reason: DisplaySelectionFailure) {
        let name = displays.name(of: id) ?? "The display"
        sessionLog.error("Display selection failed: \(String(describing: reason), privacy: .public)")
        switch reason {
        case .unavailable:
            overlays?.showDisplaySwitch(nil)
            showDefaultDisplay(after: "\(name) is no longer available.")
        case .unsupported, .busy, .timedOut:
            let status = DisplaySwitchStatus(message: "\(name) isn’t responding.") { [weak self] in
                if case .failure = self?.selectDisplay(id) { NSSound.beep() }
            }
            overlays?.showDisplaySwitch(status)
        }
    }

    /// Reads the frame back off the main actor, which the copy and the GPU wait would stall.
    func showsBlankFrame() async -> Bool {
        guard let desktop = renderer?.desktop else { return false }
        return await Task.detached { (try? desktop.snapshot())?.isBlank ?? false }.value
    }
    var lastFrameArrival: TimeInterval? { renderer?.desktop.lastFrameArrival }
    var captureFrameBaseline: Int { frameBaseline }
    func removeFrameDemand() { display.removeCommandLineDemand() }

    func resize(_ resolution: ConnectionResolution) throws {
        guard state == .connected else { throw ControlFailure(.notConnected, "The session is not connected.") }
        guard supportsDynamicResize else { throw ControlFailure(.unsupported, "The server does not support dynamic resizing.") }
        guard case .fixed(let width, let height) = resolution, resolution.isValid else {
            throw ControlFailure(.invalidArgument, "Resize requires fixed dimensions.")
        }
        if let area = session?.maximumResizeArea, UInt64(width) * UInt64(height) > area {
            throw ControlFailure(.unsupported, "The requested desktop exceeds the server's negotiated pixel area.", hint: "Choose a smaller resolution.")
        }
        attemptResolution = resolution
        display.followsWindow = false
        session?.requestResize(.init(width: width, height: height), scale: 1)
    }

    func respondToPrompt(_ id: UUID, credentials answer: SessionCredentials?, trust: Bool = false, remember: Bool = false) throws {
        guard let prompt = pendingPrompt, prompt.id == id else { throw ControlFailure(.promptResolved, "This prompt was already resolved.") }
        if case .credentials(_, let challenge) = prompt {
            if let answer, remember { try onRememberCredentials(answer) }
            credentials = answer
            // Cancelling keeps the rejection, so the saved password isn't sent next time.
            if answer != nil {
                rejectedCredentials = nil
                attemptWithholdsRejectedPassword = false
            }
            cancelChallenge = nil
            dismissChallenge(action: answer == nil ? "cancel" : "connect")
            challenge.responder.respond(answer)
        } else if case .certificate(_, let challenge) = prompt {
            cancelChallenge = nil
            dismissChallenge(action: trust ? "connect" : "cancel")
            challenge.responder.respond(trust ? .trust : .reject)
        }
    }

    var inputBackend: (any AgentInputSession)? { session as? any AgentInputSession }
    private(set) var control = SessionControl()
    static let controlDidChange = Notification.Name("SessionControlDidChange")
    private var controlFrameDemand = false
    var activeAgentInput: (any AgentInputRequest)?
    var agentInputCancellation: ControlFailure?

    /// Take Over and Stop can cancel even events detached by the C drain loop.
    /// The executor keeps admission until the source's releases are submitted.
    func cancelAgentInput(_ failure: ControlFailure) {
        guard let activeAgentInput else { return }
        agentInputCancellation = failure
        activeAgentInput.cancel()
    }

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
    /// The account the server rejected. Attempts that would send it again ask instead,
    /// and the credentials sheet starts with these values. A replaced password or another account is sent.
    private var rejectedCredentials: SessionCredentials?
    /// True when this attempt left out the rejected password, so the session reports it as missing.
    private var attemptWithholdsRejectedPassword = false
    /// The state the tab shows. Setup failures and teardown count as disconnected.
    private(set) var state: SessionState = .connecting {
        didSet {
            if state != oldValue {
                onStateChange(state)
                onControlEvent?("session.state", nil)
            }
            updateDesktopAccessibility()
        }
    }
    private let container = SessionContainerView()
    /// The status view or the desktop, filling the container.
    private var content: NSView?
    private var statusView: NSHostingView<SessionStatusView>?
    private var closed = false
    private let display: SessionDisplay
    let inputOverlays = SessionOverlayState()
    private var overlayScale = 1.0
    lazy var capture = SessionCapture(media: AppleCaptureMedia(overlays: inputOverlays), destination: ScreenshotDestination { AppSettings.saveFolder })

    init(
        connection: Connection, credentialStore: CredentialStore,
        onStateChange: @escaping (SessionState) -> Void,
        onAttentionChange: @escaping (Bool) -> Void,
        onKeyboardCaptureChange: @escaping (Bool) -> Void,
        onClose: @escaping () -> Void,
        onPromptResolved: @escaping (UUID) -> Void,
        onRememberCredentials: @escaping (SessionCredentials) throws -> Void
    ) {
        self.connection = connection
        self.attemptConnection = connection
        self.credentialStore = credentialStore
        self.onStateChange = onStateChange
        self.onAttentionChange = onAttentionChange
        self.onKeyboardCaptureChange = onKeyboardCaptureChange
        self.onClose = onClose
        self.onPromptResolved = onPromptResolved
        self.onRememberCredentials = onRememberCredentials
        display = SessionDisplay(view: container)
        super.init(nibName: nil, bundle: nil)
        display.onScaleChange = { [weak self] scale in
            guard let self, overlayScale != scale else { return }
            overlayScale = scale
            refreshOverlaySettings()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshOverlaySettings),
            name: UserDefaults.didChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshReduceMotion),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshReduceMotion()
        refreshOverlaySettings()
        capture.onRecordingStateChange = { [weak self] in
            self?.onControlEvent?("recording.state", nil)
            self?.reportRecording()
        }
        capture.onRecordingActivityChange = { [weak self] active in
            self?.display.setRecording(active)
            self?.updateDesktopAccessibility()
            if !active { self?.reportRecordingResult() }
        }
        container.onResize = { [weak self] in self?.display.requestResize() }
        container.onVisibilityChange = { [weak self] in
            self?.display.visibilityChanged()
            self?.overlays?.presentationChanged()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(connection:credentialStore:onStateChange:onAttentionChange:onKeyboardCaptureChange:onClose:)")
    }

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        eventTask?.cancel()
        session?.disconnect()
        cancelChallenge?()
        sessionLog.info("Session released")
    }

    override func loadView() {
        view = container
    }

    /// Starts an attempt. Visible Fit to Window tabs measure their content area; hidden tabs use the fallback.
    func start() {
        startSession()
    }

    func reconnect() {
        configureCommandLine(agent: commandLine ? startedBy : nil, resolution: nil)
        startSession()
    }

    /// Takes the saved connection after an edit. A running session keeps its settings; the next
    /// attempt uses the new ones and reads the password from the Keychain again.
    func update(_ connection: Connection) {
        // A rejection applies only to the server that made it.
        if (connection.kind, connection.host, connection.port) != (self.connection.kind, self.connection.host, self.connection.port) {
            rejectedCredentials = nil
        }
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
        endAgentControl()
        finishCapture()
        capture.setSource(nil)
        retiredFrameRevision = frameRevision
        renderer = nil
        displays = SessionDisplays()
        displayNotice = nil
        shownDisplay = false
        onDisplayChange?(nil)
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
    func windowDidTransition() {
        display.didTransition()
        overlays?.presentationChanged()
    }

    /// In full screen the toolbar slides in over the top of the remote screen.
    func toolbarRevealed(_ revealed: Bool) { overlays?.toolbarRevealed(revealed) }
    func windowDidChangeSize() { display.requestResize() }

    // MARK: Session menu

    var canDisconnect: Bool { session != nil }
    var canReconnect: Bool { session == nil && !closed }
    var isConnected: Bool { state == .connected }
    var hasKeyboard: Bool { control.allowsHumanInput && state == .connected && view.window?.firstResponder === desktopView }

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
            switch result {
            case .success: self?.overlays?.confirm("Recording Saved", sound: false)
            case .failure(let failure):
                sessionLog.error("Capture: \(failure.localizedDescription, privacy: .public)")
                self?.presentCaptureFailure(failure)
            case nil: break
            }
        }
    }

    private func reportRecording() {
        if case .recording = capture.recordingState { overlays?.recordingChanged(true) } else { overlays?.recordingChanged(false) }
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
        guard displayIsReady else { throw CaptureFailure.noFrame }
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

    func startRecording() throws {
        guard displayIsReady else { throw CaptureFailure.noFrame }
        try capture.startRecording(connectionName: connection.name)
    }

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
        inputOverlays.reset()
        attemptID = UUID()
        attemptConnection = connection
        frameBaseline = 0
        retiredFrameRevision = 0
        desktopSize = nil
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
                    username: connection.username, domain: connection.kind == .rdp ? connection.domain ?? "" : "",
                    password: try credentialStore.password(for: connection.id) ?? ""
                )
                credentials = currentCredentials
            }
            attemptWithholdsRejectedPassword =
                rejectedCredentials.map {
                    ($0.username, $0.domain, $0.password) == (currentCredentials.username, currentCredentials.domain, currentCredentials.password)
                } ?? false
            let renderer = try FrameRenderer()
            self.renderer = renderer
            view.window?.contentView?.layoutSubtreeIfNeeded()
            let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let points = connectingView.bounds.size
            let desktopSize: DesktopSize
            let scaleFactor: Double
            let allowsDynamicResize: Bool
            let resolution = attemptResolution ?? connection.resolution
            display.followsWindow = resolution == .fitToWindow
            switch resolution {
            case .fitToWindow:
                // Hidden tabs start at 1920x1080 until a visible window can supply its size.
                desktopSize =
                    view.window != nil && points.width > 0 && points.height > 0
                    ? DesktopSize(width: Int(points.width * backingScale), height: Int(points.height * backingScale))
                    : DesktopSize(width: 1920, height: 1080)
                scaleFactor = view.window == nil ? 1 : backingScale
                allowsDynamicResize = true
            case .fixed(let width, let height):
                desktopSize = DesktopSize(width: width, height: height)
                scaleFactor = 1
                allowsDynamicResize = commandLine
            }
            sessionLog.info("Requested desktop: \(desktopSize.width)x\(desktopSize.height), scale=\(scaleFactor), dynamic=\(allowsDynamicResize)")
            let configuration = SessionConfiguration(
                host: connection.host, port: port, username: currentCredentials.username,
                domain: currentCredentials.domain,
                password: attemptWithholdsRejectedPassword || currentCredentials.password.isEmpty ? nil : currentCredentials.password,
                desktopSize: desktopSize, scaleFactor: scaleFactor, allowsDynamicResize: allowsDynamicResize,
                vncMode: connection.vncMode
            )
            capture.setSource(renderer.desktop)
            let inputOverlays = inputOverlays
            overlayScale = scaleFactor
            refreshOverlaySettings()
            let inputFeedback: @Sendable (InputSource, SessionInputFeedback) -> Void = { source, event in
                inputOverlays.receive(source, event)
            }
            let session: any RemoteSession =
                switch connection.kind {
                case .rdp:
                    RDPSession(
                        configuration: configuration, frameSink: renderer, inputFeedback: inputFeedback,
                        configurationDirectory: AppIdentity.current.supportDirectory.appending(path: "FreeRDP", directoryHint: .isDirectory))
                case .vnc:
                    VNCSession(
                        configuration: configuration, frameSink: renderer, inputFeedback: inputFeedback,
                        certificateStoreURL: AppIdentity.current.supportDirectory.appending(path: "VNC/certificates", directoryHint: .isDirectory))
                }
            let desktopView = RemoteDesktopView(renderer: renderer)
            desktopView.allowsHumanInput = control.allowsHumanInput
            desktopView.onHumanInput = { [weak self] kind in self?.control.record(kind) }
            desktopView.onBlockedInput = { [weak self] in self?.overlays?.inputBlocked() }
            desktopView.input = session
            desktopView.overlayState = inputOverlays
            updateOverlayCursor(.systemDefault)
            self.desktopView = desktopView
            overlays = SessionOverlays(
                desktop: desktopView, computerName: connection.name, address: connection.displayAddress,
                cancel: { [weak session] in session?.disconnect() },
                toggleControl: { [weak self] in self?.toggleAgentControl() },
                stopRecording: { [weak self] in Task { await self?.stopRecording() } }
            )
            overlays?.controlChanged(control, agent: agentName, announcesStop: false)
            reportRecording()
            refreshOverlaySettings()
            self.session = session
            remoteClipboard = RemoteClipboard()
            clipboardSync = ClipboardSync(session: session, canSync: { [weak self] in self?.canSyncMacClipboard == true })
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
            if case .reconnecting = state, previous == .connected { attemptID = UUID() }
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
                // One recovery cycle keeps one ID through its attempts and any certificate prompt.
                desktopView.setSessionConnected(false)
                if let window = view.window, window.firstResponder === desktopView {
                    window.makeFirstResponder(nil)
                }
                if case .reconnecting = previous {
                } else {
                    announce("Reconnecting to “\(connection.name)”, attempt \(attempt) of \(SessionStatusView.reconnectAttemptLimit)")
                }
                overlays?.reconnecting(attempt: attempt)
            case .disconnected(let reason):
                if reason == .authenticationFailed { rejectedCredentials = credentials }
                endAgentControl()
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
        case .clipboardChanged(let revision, let status):
            if remoteClipboard.update(revision: revision, status: status), case .received(let flavors) = status {
                clipboardSync?.receiveRemoteItem(flavors)
            }
        case .desktopSizeChanged(let size, _):
            if desktopSize != size { inputGeometryRevision += 1 }
            desktopSize = size
            inputOverlays.setDesktopSize(CGSize(width: size.width, height: size.height))
            // The window never resizes for a session. The renderer aspect-fits any desktop size.
            sessionLog.info("Desktop size: \(size.width)x\(size.height)")
        case .dynamicResizeChanged(let available):
            if available { display.requestResize() }
        case .displaysChanged(let displays):
            applyDisplays(displays)
        case .displaySelectionFailed(let id, let reason):
            displaySelectionFailed(id, reason)
        case .cursorChanged(let cursor):
            desktopView.apply(cursor: cursor)
            updateOverlayCursor(cursor)
        case .credentialsChallenge(let reported):
            let challenge =
                reported.reason == .missing && attemptWithholdsRejectedPassword
                ? CredentialsChallenge(
                    username: reported.username, domain: reported.domain, reason: .rejected,
                    responder: reported.responder, fields: reported.fields)
                : reported
            dismissChallenge()
            credentialDraft = SessionCredentialDraft(challenge: challenge, password: credentials?.password ?? "")
            pendingPrompt = .credentials(UUID(), challenge)
            cancelChallenge = { challenge.responder.respond(nil) }
            presentWhenShown { [weak self] window in self?.showCredentials(challenge, on: window) }
        case .trustChallenge(let challenge):
            dismissChallenge()
            pendingPrompt = .certificate(UUID(), challenge)
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
        let promptID = pendingPrompt?.id
        guard let credentialDraft else { return }
        let form = SessionCredentialsView(
            challenge: challenge, computerName: connection.name, address: connection.displayAddress,
            showsDomain: attemptConnection.kind == .rdp, draft: credentialDraft,
            onCancel: { [weak self] in
                guard let self, let promptID, pendingPrompt?.id == promptID else { return }
                try? respondToPrompt(promptID, credentials: nil)
            },
            onConnect: { [weak self] answer, remember in
                guard let self else {
                    challenge.responder.respond(nil)
                    return
                }
                guard let promptID, pendingPrompt?.id == promptID else { return }
                do { try respondToPrompt(promptID, credentials: answer, remember: remember) } catch {
                    NSApplication.shared.presentError(
                        error, modalFor: self.sheet ?? window, delegate: nil,
                        didPresent: nil, contextInfo: nil)
                }
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
        let address =
            Int(challenge.port) == attemptConnection.defaultPort
            ? challenge.host : "\(challenge.host):\(challenge.port)"
        let alert = NSAlert()
        var details = [("Subject", challenge.subject), ("Issuer", challenge.issuer), ("SHA-256", challenge.fingerprint)]
            .filter { !$0.1.isEmpty }
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
        let promptID = pendingPrompt?.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let promptID, pendingPrompt?.id == promptID else { return }
            try? respondToPrompt(promptID, credentials: nil, trust: response == connectButton)
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
            field.font =
                label.hasSuffix("SHA-256")
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
    private func dismissChallenge(action: String = "cancel") {
        if let prompt = pendingPrompt {
            pendingPrompt = nil
            credentialDraft = nil
            onPromptResolved(prompt.id)
            onControlEvent?(
                "prompt.resolved",
                .object([
                    "prompt": .string(prompt.id.uuidString),
                    "session": .string(attemptID.uuidString), "action": .string(action),
                ]))
        }
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
            onReconnect: { [weak self] in self?.reconnect() },
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
        NSAccessibility.post(
            element: view, notification: .announcementRequested,
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
        if let name = displays.name(of: displays.pendingID ?? displays.selectedID) {
            parts.append(displays.pendingID == nil ? "\(name) of \(displays.displays.count)" : "switching to \(name)")
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

// MARK: Agent control

extension SessionViewController {
    func checkAgentInput() throws {
        do { try control.checkInput() } catch SessionControl.Refusal.userActive {
            throw ControlFailure(
                .userActive, "The user has taken control of this session.")
        } catch SessionControl.Refusal.agentStopped {
            throw Self.agentStopped
        } catch SessionControl.Refusal.observationRequired {
            throw ControlFailure(.observationRequired, "Take a new screenshot before sending input.")
        } catch {
            throw ControlFailure(.inputBusy, "Control is being transferred.")
        }
    }

    static let agentStopped = ControlFailure(.agentStopped, "The user stopped agent control of this session.")

    /// A nil `agent` comes from a request that did not name its program.
    func attachAgentControl(agent: String?) throws {
        try checkAgentInput()
        try control.attach()
        agentName = agent ?? "remora CLI"
        applyControl()
    }

    @objc private func refreshOverlaySettings() {
        inputOverlays.configure(
            showPointerInRecordings: AppSettings.showPointerInRecordings,
            showKeyPresses: AppSettings.showKeyPresses,
            showAgentPointer: AppSettings.showAgentPointer,
            scale: overlayScale, keyPressSize: AppSettings.keyPressSize)
    }

    @objc private func refreshReduceMotion() {
        inputOverlays.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Timing follows the output that can actually present this tab's cursor.
    var isAgentCursorPresented: Bool {
        if AppSettings.showPointerInRecordings, case .recording = capture.recordingState { return true }
        guard AppSettings.showAgentPointer, let window = desktopView?.window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private func updateOverlayCursor(_ cursor: RemoteCursor) {
        if cursor == .hidden {
            inputOverlays.setCursor(nil, hotspot: .zero)
            return
        }
        let native = cursor.cursor(pointsPerPixel: 1)
        inputOverlays.setCursor(native.image.cgImage(forProposedRect: nil, context: nil, hints: nil), hotspot: native.hotSpot)
    }

    /// Take Over while the agent has control, or Resume while it is paused.
    func toggleAgentControl() {
        guard !control.isTransferring else { return }
        Task {
            do {
                if control.canResume { try resumeAgentControl() } else { try await handoverAgentControl(.takeOver) }
            } catch { NSApp.presentError(error) }
        }
    }

    func observedForAgent() { control.observed() }

    /// Runs independently of a CLI caller's cancellation. Human forwarding stays
    /// closed until the input executor has completed its session-thread releases.
    /// Only `.release` comes from the CLI; the user's Take Over and Stop come from the UI.
    func handoverAgentControl(_ kind: SessionControl.Handover) async throws {
        if control.isTransferring { throw ControlFailure(.inputBusy, "Control is being transferred.") }
        let from = control.state.rawValue
        guard control.beginHandover(kind, frame: frameRevision) else { return }
        inputGeometryRevision += 1
        applyControl()
        let failure =
            switch kind {
            case .takeOver:
                ControlFailure(
                    .userActive, "The user has taken control of this session.")
            case .stop: Self.agentStopped
            case .release: ControlFailure(.cancelled, "Agent control was released.")
            }
        cancelAgentInput(failure)
        // The executor owns finish(). A failed release closes the transport, and a
        // recovered reconnect releases every source before new input, so neither
        // case can leave agent-held state under human input. A session that ends
        // meanwhile has already settled the handover.
        while activeAgentInput != nil {
            await Task.detached { try? await Task.sleep(for: .milliseconds(5)) }.value
        }
        control.completeHandover()
        applyControl()
        onControlEvent?(
            kind == .takeOver ? "user.tookOver" : "control.stopped",
            .object([
                "session": .string(attemptID.uuidString), "by": .string(kind == .release ? "cli" : "ui"), "from": .string(from),
                "screenStale": .bool(true),
            ]))
    }

    /// Throws `user-active` or `agent-stopped` while the user holds control or is taking it.
    /// CLI commands that would send input, start the session again or discard the tab's hold check this first.
    func checkUserHold() throws {
        if control.canResume || control.isTransferring { try checkAgentInput() }
    }

    func resumeAgentControl() throws {
        guard isConnected else { throw ControlFailure(.notConnected, "The session is not connected.") }
        let from = control.state.rawValue
        guard let summary = control.resume(frame: frameRevision) else {
            if control.isTransferring { throw ControlFailure(.inputBusy, "Control is being transferred.") }
            return
        }
        inputGeometryRevision += 1
        applyControl()
        onControlEvent?(
            "user.resumed",
            .object([
                "session": .string(attemptID.uuidString), "by": .string("ui"), "from": .string(from),
                "counts": .object([
                    "clicks": .number(Double(summary.counts.clicks)),
                    "keys": .number(Double(summary.counts.keys)), "scrolls": .number(Double(summary.counts.scrolls)),
                ]),
                "screenChanged": .bool(summary.screenChanged), "screenStale": .bool(true), "observationRequired": .bool(true),
            ]))
    }

    private func endAgentControl() {
        cancelAgentInput(ControlFailure(.sessionEnded, "The session ended during input."))
        control.ended()
        applyControl(sessionEnded: true)
    }

    private func applyControl(sessionEnded: Bool = false) {
        // Disable clipboard synchronization before closing the human input gate.
        if allowsMacClipboardSync != control.allowsHumanInput {
            allowsMacClipboardSync = control.allowsHumanInput
        }
        desktopView?.allowsHumanInput = control.allowsHumanInput
        overlays?.controlChanged(control, agent: agentName, announcesStop: isConnected && !sessionEnded)
        inputOverlays.setAgentCursorVisible(control.state == .active && !sessionEnded)
        if sessionEnded { inputOverlays.reset() }
        refreshOverlaySettings()
        if control.needsFrames != controlFrameDemand {
            controlFrameDemand = control.needsFrames
            if controlFrameDemand { addFrameDemand() } else { removeFrameDemand() }
        }
        NotificationCenter.default.post(name: Self.controlDidChange, object: self)
    }
}

extension SessionDisplays {
    /// Left to right, then top to bottom, as the menus number them.
    var ordered: [RemoteDisplay] { displays.sorted { ($0.x, $0.y, $0.id) < ($1.x, $1.y, $1.id) } }

    /// "Display 2" in menu order, or nil when there is nothing to choose between.
    func name(of id: UInt32?) -> String? {
        guard displays.count > 1, let id, let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        return "Display \(index + 1)"
    }

    /// The display the remote marks as main, otherwise the first in menu order.
    var defaultID: UInt32? { (displays.first(where: \.isMain) ?? ordered.first)?.id }
}
