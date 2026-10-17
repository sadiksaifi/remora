import AppKit
import RDPSession
import RemoraCore
import SwiftUI
import os

private let sessionLog = Logger(subsystem: "dev.sadiksaifi.Remora", category: "SessionWindow")

/// Owns a single-use session per attempt. Closing cancels both the stream and any sheet.
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let connection: Connection
    private let credentialStore: CredentialStore
    private let onClose: (SessionWindowController) -> Void
    private var session: (any RemoteSession)?
    private var clipboardSync: ClipboardSync?
    private var overlays: SessionOverlays?
    private weak var desktopView: RemoteDesktopView?
    private var eventTask: Task<Void, Never>?
    private var sheet: NSWindow?
    private var cancelChallenge: (() -> Void)?
    private var credentials: SessionCredentials?
    private var state: SessionState?
    private var statusView: NSHostingView<SessionStatusView>?
    private var closed = false
    private let display = SessionWindowDisplay()

    init(connection: Connection, credentialStore: CredentialStore, onClose: @escaping (SessionWindowController) -> Void) {
        self.connection = connection
        self.credentialStore = credentialStore
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = connection.name
        window.subtitle = connection.displayAddress
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "Session"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        super.init(window: window)
        window.delegate = self
        startSession()
    }

    required init?(coder: NSCoder) { fatalError("Use init(connection:credentialStore:onClose:)") }

    isolated deinit {
        eventTask?.cancel()
        session?.disconnect()
        cancelChallenge?()
        sessionLog.info("Session window released")
    }

    func disconnect() {
        state = nil
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
        // Removing the view stops its display link as well.
        window?.contentViewController = nil
        window?.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        closed = true
        disconnect()
        onClose(self)
    }

    func windowDidResize(_ notification: Notification) { display.requestResize() }
    func windowDidEndLiveResize(_ notification: Notification) { display.requestResize() }
    func windowDidChangeBackingProperties(_ notification: Notification) { display.requestResize() }
    func windowDidChangeScreen(_ notification: Notification) { display.requestResize() }
    func windowWillEnterFullScreen(_ notification: Notification) { display.willTransition() }
    func windowWillExitFullScreen(_ notification: Notification) { display.willTransition() }
    func windowDidEnterFullScreen(_ notification: Notification) { display.didTransition() }
    func windowDidExitFullScreen(_ notification: Notification) { display.didTransition() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { display.didTransition() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { display.didTransition() }

    // MARK: Session menu

    @objc func disconnectSession(_ sender: Any?) { session?.disconnect() }
    @objc func reconnectSession(_ sender: Any?) { startSession() }
    @objc func sendCtrlAltDelete(_ sender: Any?) { desktopView?.sendCtrlAltDelete() }

    @objc func releaseKeyboardCapture(_ sender: Any?) {
        guard let window, window.firstResponder === desktopView else { return }
        window.makeFirstResponder(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(disconnectSession(_:)): session != nil
        case #selector(reconnectSession(_:)): session == nil && !closed
        case #selector(sendCtrlAltDelete(_:)): state == .connected
        case #selector(releaseKeyboardCapture(_:)): state == .connected && window?.firstResponder === desktopView
        default: true
        }
    }

    private func startSession() {
        guard !closed, let window else { return }
        disconnect()
        let connectingView = showStatus(.connecting)
        do {
            guard let port = UInt16(exactly: connection.port), port > 0 else {
                showStatus(.disconnected(.protocolError("The connection port must be between 1 and 65535.")))
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
            let size = window.convertToBacking(connectingView.bounds).size
            let configuration = SessionConfiguration(
                host: connection.host, port: port, username: currentCredentials.username,
                domain: currentCredentials.domain,
                password: currentCredentials.password.isEmpty ? nil : currentCredentials.password,
                desktopSize: DesktopSize(width: Int(size.width), height: Int(size.height)),
                scaleFactor: window.backingScaleFactor
            )
            let session = RDPSession(configuration: configuration, frameSink: RendererFrameSink(renderer: renderer))
            let desktopView = RemoteDesktopView(renderer: renderer)
            desktopView.input = session
            self.desktopView = desktopView
            overlays = SessionOverlays(
                desktop: desktopView, computerName: connection.name, address: connection.displayAddress
            ) { [weak session] in session?.disconnect() }
            self.session = session
            clipboardSync = ClipboardSync(session: session)
            desktopView.onFocus = { [weak self] in self?.clipboardSync?.focusGained() }
            display.attach(session, to: window)
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
            showStatus(.disconnected(.protocolError(error.localizedDescription)))
        }
    }

    private func receive(_ event: SessionEvent, desktopView: RemoteDesktopView) {
        guard !closed, let window else { return }
        switch event {
        case .stateChanged(let state):
            sessionLog.info("State: \(String(describing: state), privacy: .public)")
            self.state = state
            switch state {
            case .connecting:
                if window.contentView !== desktopView { showStatus(.connecting) }
            case .awaitingCredentials:
                if window.contentView !== desktopView { showStatus(.awaitingCredentials) }
            case .awaitingTrust:
                if window.contentView !== desktopView { showStatus(.awaitingTrust) }
            case .connected:
                clipboardSync?.sessionDidConnect()
                dismissChallenge()
                if window.contentView !== desktopView { window.contentView = desktopView }
                overlays?.connected()
                window.makeFirstResponder(desktopView)
                display.didConnect()
                desktopView.setSessionConnected(true)
            case .reconnecting(let attempt):
                desktopView.setSessionConnected(false)
                window.makeFirstResponder(nil)
                overlays?.reconnecting(attempt: attempt)
            case .disconnected(let reason):
                desktopView.setSessionConnected(false)
                overlays = nil
                clipboardSync = nil
                dismissChallenge()
                session = nil
                display.disconnect()
                showStatus(.disconnected(reason))
            }
        case .remoteClipboardText(let text):
            clipboardSync?.receiveRemoteText(text)
        case .desktopSizeChanged(let size, let requested):
            sessionLog.info("Desktop size: \(size.width)x\(size.height)")
            if !requested { resizeWindow(to: size) }
        case .dynamicResizeChanged(let available):
            if available { display.requestResize() }
        case .cursorChanged(let cursor):
            desktopView.apply(cursor: cursor)
        case .credentialsChallenge(let challenge):
            showCredentials(challenge)
        case .trustChallenge(let challenge):
            showTrust(challenge)
        }
    }

    private func resizeWindow(to size: DesktopSize) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen, size.width > 0, size.height > 0 else { return }
        display.applyingRemoteSize = true
        defer { display.applyingRemoteSize = false }
        let visible = screen.visibleFrame
        let chrome = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let desired = NSSize(width: CGFloat(size.width) / window.backingScaleFactor,
                             height: CGFloat(size.height) / window.backingScaleFactor)
        let factor = min(1, visible.width / desired.width, max(1, visible.height - chrome) / desired.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(
            width: desired.width * factor, height: desired.height * factor
        )))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        window.setFrame(frame, display: true)
    }

    private func showCredentials(_ challenge: CredentialsChallenge) {
        guard let window else { challenge.responder.respond(nil); return }
        dismissChallenge()
        cancelChallenge = { challenge.responder.respond(nil) }
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

    private func showTrust(_ challenge: TrustChallenge) {
        guard let window else { challenge.responder.respond(.reject); return }
        dismissChallenge()
        cancelChallenge = { challenge.responder.respond(.reject) }
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

    private func dismissChallenge() {
        let cancel = cancelChallenge
        cancelChallenge = nil
        cancel?()
        if let sheet {
            self.sheet = nil
            window?.endSheet(sheet, returnCode: .cancel)
            sheet.orderOut(nil)
            sheet.contentViewController = nil
        }
    }

    /// Replaces the window content with a status view, removing any desktop.
    @discardableResult
    private func showStatus(_ status: SessionStatus) -> NSView {
        let content = SessionStatusView(
            status: status, computerName: connection.name, address: connection.displayAddress,
            onCancel: { [weak self] in self?.session?.disconnect() },
            onReconnect: { [weak self] in self?.startSession() },
            onClose: { [weak self] in self?.window?.performClose(nil) }
        )
        if let statusView, window?.contentView === statusView {
            statusView.rootView = content
            return statusView
        }
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        window?.contentView = view
        statusView = view
        return view
    }
}

private struct RendererFrameSink: FrameSink {
    let renderer: FrameRenderer

    func consume(_ frame: BorrowedFrame) {
        renderer.ingest(pixels: frame.pixels, width: frame.width, height: frame.height,
                        bytesPerRow: frame.stride, dirty: frame.dirtyRectangles.map {
            DirtyRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        })
    }
}
