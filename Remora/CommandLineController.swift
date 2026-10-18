import AppKit
import RemoraControl

/// Maps wire commands to app operations. Future command families enter through handle(_:).
@MainActor
final class CommandLineController {
    private let mainWindow: MainWindowController
    private let sessions: SessionTabs
    private let show: (String?) -> Void
    private let quit: () -> Void
    private var server: ControlServer?

    init(mainWindow: MainWindowController, sessions: SessionTabs,
         show: @escaping (String?) -> Void, quit: @escaping () -> Void) {
        self.mainWindow = mainWindow
        self.sessions = sessions
        self.show = show
        self.quit = quit
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
            settingsVisible: NSApplication.shared.windows.contains { $0.title == "Settings" && $0.isVisible },
            sessions: sessions.tabs.count
        )))
    }

    private func handle(_ request: ControlRequest) -> ControlReply {
        do {
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
                return ControlReply(.success(.object(["quitting": .bool(true)]))) { [weak self] in
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
