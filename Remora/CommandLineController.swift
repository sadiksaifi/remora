import AppKit
import RemoraControl
import RemoraCore

/// Maps wire commands to app operations. Future command families enter through handle(_:).
@MainActor
final class CommandLineController {
    let mainWindow: MainWindowController
    let sessions: SessionTabs
    let show: (String?) -> Void
    private let quit: () -> Void
    private var server: ControlServer?
    let connectionStore: ConnectionStore
    let credentialStore: CredentialStore
    var screenshotReceipts: [ScreenshotReceipt] = []
    var eventSubscribers: [UUID: EventSubscriber] = [:]
    let eventInstance = UUID()
    var eventSequence = 0

    init(mainWindow: MainWindowController, sessions: SessionTabs,
         connectionStore: ConnectionStore, credentialStore: CredentialStore,
         show: @escaping (String?) -> Void, quit: @escaping () -> Void) {
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.mainWindow = mainWindow
        self.sessions = sessions
        self.show = show
        self.quit = quit
        sessions.onControlEvent = { [weak self] type, session, data in self?.publishEvent(type, session: session, data: data) }
    }

    func start() async throws {
        let server = ControlServer(endpoint: try ControlEndpoint()) { [weak self] request in
            guard let self else { return ControlReply(.failure(ControlFailure(.appUnavailable, "Remora is stopping."))) }
            return await self.handle(request)
        }
        try await server.start()
        self.server = server
    }

    func stop() async { await server?.stop() }

    private func finishQuit() {
        // terminateLater runs a nested AppKit loop. Enter it from the run loop,
        // leaving both the Swift executor and main dispatch queue free to finish captures.
        RunLoop.main.perform(inModes: [.common]) { [self] in
            MainActor.assumeIsolated { quit() }
        }
    }

    private func status() throws -> ControlResponse {
        .success(try .encoding(AppStatus(
            running: true, pid: ProcessInfo.processInfo.processIdentifier,
            hidden: NSApplication.shared.isHidden,
            windowVisible: mainWindow.window?.isVisible == true,
            settingsVisible: NSApplication.shared.settingsWindow?.isVisible == true,
            sessions: sessions.tabs.count
        )))
    }

    private func handle(_ request: ControlRequest) async -> ControlReply {
        do {
            if Task.isCancelled { throw ControlFailure(.cancelled, "The command was interrupted.") }
            if request.command.hasPrefix("settings.") {
                return ControlReply(.success(try handleSettings(request)))
            }
            if request.command.hasPrefix("clipboard.") {
                return ControlReply(.success(try await handleClipboard(request)))
            }
            if request.command == "events" { return try subscribeEvents(request) }
            let waitCondition = request.command == "wait" ? try request.string("for") : nil
            if request.command == "screenshot" || request.command.hasPrefix("recording.") ||
                ["frame", "recording-finished"].contains(waitCondition ?? "") {
                return try await handleScreen(request)
            }
            if request.command.hasPrefix("connection.") {
                return ControlReply(.success(try handleConnection(request)))
            }
            if request.command == "connect" || request.command == "wait" || request.command.hasPrefix("session.") || request.command.hasPrefix("prompt.") {
                return ControlReply(.success(try await handleSession(request)))
            }
            let allowed: Set<String> = request.command == "app.show" ? ["page"] : []
            guard request.session == nil, Set(request.arguments.keys).isSubset(of: allowed) else {
                throw ControlFailure(.invalidArgument, "This app command received unknown arguments.")
            }
            switch request.command {
            case "app.status": return ControlReply(try status())
            case "app.show":
                var page: String?
                if let value = request.arguments["page"] {
                    guard case .string(let name) = value, ["connections", "settings"].contains(name) else {
                        throw ControlFailure(.invalidArgument, "page must be connections or settings.")
                    }
                    page = name
                }
                show(page)
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.allowsRunningApplicationSubstitution = false
                configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                    eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration, completionHandler: nil)
            case "app.hide": NSApplication.shared.hide(nil)
            case "app.close": mainWindow.window?.close()
            case "app.quit":
                let failures = await sessions.prepareToQuit()
                let response: ControlResponse = failures.isEmpty
                    ? .success(.object(["quitting": .bool(true)]))
                    : .failure(ControlFailure(.captureFailed, failures.map(\.localizedDescription).joined(separator: "\n")))
                return ControlReply(response) { [weak self] in
                    await self?.finishQuit()
                }
            default:
                throw ControlFailure(.unknownCommand, "Unknown command '\(request.command)'.", hint: "Run remora --help.")
            }
            return ControlReply(.success(.object([:])))
        } catch let failure as ControlFailure { return ControlReply(.failure(failure)) }
        catch { return ControlReply(.failure(ControlFailure(.internal, error.localizedDescription))) }
    }
}
