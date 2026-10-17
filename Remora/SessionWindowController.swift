import AppKit
import RDPSession
import RemoraCore
import SwiftUI
import os

private let sessionLog = Logger(subsystem: "dev.sadiksaifi.Remora", category: "SessionWindow")

/// Owns a single-use session per attempt. Closing cancels both the stream and any sheet.
@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate {
    let connection: Connection
    private let credentialStore: CredentialStore
    private let onClose: (SessionWindowController) -> Void
    private var session: (any RemoteSession)?
    private var clipboardSync: ClipboardSync?
    private var eventTask: Task<Void, Never>?
    private var sheet: NSWindow?
    private var cancelChallenge: (() -> Void)?
    private var credentials: SessionCredentials?
    private var closed = false

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
        clipboardSync = nil
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

    @objc private func reconnect(_ sender: Any?) { startSession() }
    @objc private func closeSession(_ sender: Any?) { window?.performClose(sender) }

    private func startSession() {
        guard !closed, let window else { return }
        disconnect()
        let connectingView = Self.connectingView(name: connection.name)
        window.contentView = connectingView
        do {
            guard let port = UInt16(exactly: connection.port), port > 0 else {
                showDisconnected("The connection port must be between 1 and 65535.")
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
            self.session = session
            clipboardSync = ClipboardSync(session: session)
            desktopView.onFocus = { [weak self] in self?.clipboardSync?.focusGained() }
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
            showDisconnected(error.localizedDescription)
        }
    }

    private func receive(_ event: SessionEvent, desktopView: RemoteDesktopView) {
        guard !closed, let window else { return }
        switch event {
        case .stateChanged(let state):
            sessionLog.info("State: \(String(describing: state), privacy: .public)")
            switch state {
            case .connecting, .awaitingCredentials, .awaitingTrust:
                break
            case .connected:
                clipboardSync?.sessionDidConnect()
                dismissChallenge()
                window.contentView = desktopView
                window.makeFirstResponder(desktopView)
            case .disconnected(let reason):
                clipboardSync = nil
                dismissChallenge()
                session = nil
                showDisconnected(reason?.description ?? "The session ended.")
            }
        case .remoteClipboardText(let text):
            clipboardSync?.receiveRemoteText(text)
        case .desktopSizeChanged(let size):
            sessionLog.info("Desktop size: \(size.width)x\(size.height)")
            resizeWindow(to: size)
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
            challenge: challenge, password: credentials?.password ?? "",
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
        let alert = NSAlert()
        var warning = ""
        if case .changed(let oldFingerprint) = challenge.status {
            alert.alertStyle = .warning
            alert.messageText = "The server certificate has changed"
            warning = "A changed certificate may mean someone is impersonating this server. Only trust it if you expected this change.\n\nPrevious SHA-256 fingerprint:\n\(oldFingerprint)\n\n"
        } else {
            alert.messageText = "Trust this server certificate?"
        }
        alert.informativeText = "\(warning)Host: \(challenge.host):\(challenge.port)\n\nSubject: \(challenge.subject)\nIssuer: \(challenge.issuer)\n\nSHA-256 fingerprint:\n\(challenge.fingerprint)"
        alert.addButton(withTitle: "Trust")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let certificateSheet = alert.window
        sheet = certificateSheet
        alert.beginSheetModal(for: window) { [weak self, weak certificateSheet] response in
            challenge.responder.respond(response == .alertFirstButtonReturn ? .trust : .reject)
            guard let self, sheet === certificateSheet else { return }
            cancelChallenge = nil
            sheet = nil
        }
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

    private func showDisconnected(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        let reconnect = NSButton(title: "Reconnect", target: self, action: #selector(reconnect(_:)))
        reconnect.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(closeSession(_:)))
        let buttons = NSStackView(views: [close, reconnect])
        buttons.spacing = 8
        window?.contentView = Self.centered([label, buttons])
    }

    private static func connectingView(name: String) -> NSView {
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.startAnimation(nil)
        let label = NSTextField(labelWithString: "Connecting to \(name)...")
        label.textColor = .secondaryLabelColor
        return centered([progress, label])
    }

    private static func centered(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
        ])
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
