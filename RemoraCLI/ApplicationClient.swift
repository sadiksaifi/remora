import AppKit
import RemoraControl

/// Launch Services owns app identity and startup. Only read-only probes are retried.
@MainActor
struct ApplicationClient {
    private var bundleURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var running: Bool {
        let developmentSocket = ProcessInfo.processInfo.environment["REMORA_SOCKET"] != nil
        return NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && (developmentSocket
                ? $0.bundleURL?.resolvingSymlinksInPath() == bundleURL
                : $0.bundleIdentifier == "dev.sadiksaifi.Remora")
        }
    }

    func request(_ request: ControlRequest, launch: Bool, timeout: Double) async throws -> ControlResponse {
        let client = ControlClient(endpoint: try ControlEndpoint())
        let wasRunning = running
        if !launch {
            do { return try await client.request(request, timeout: timeout, isMutation: false) }
            catch let failure as ControlFailure where failure.code == .appUnavailable && !wasRunning {
                return .success(try .encoding(AppStatus(running: false)))
            }
        }
        do {
            _ = try await client.request(ControlRequest(command: "app.status"), timeout: 1, isMutation: false)
        } catch let failure as ControlFailure where failure.code == .cancelled {
            throw failure
        } catch {
            if !wasRunning { try openApplication() }
            try await waitForReadiness(client)
        }
        return try await client.request(request, timeout: timeout)
    }

    private func openApplication() throws {
        guard Bundle(url: bundleURL)?.bundleIdentifier == "dev.sadiksaifi.Remora" else {
            throw ControlFailure(.appUnavailable, "The helper could not find its containing Remora.app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        configuration.allowsRunningApplicationSubstitution = false
        if let socket = ProcessInfo.processInfo.environment["REMORA_SOCKET"] {
            configuration.environment = ["REMORA_SOCKET": socket]
        }
        configuration.arguments = ["--cli-background"]
        // A second simultaneous CLI launch must not send a window-opening reopen event.
        configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration, completionHandler: nil)
    }

    private func waitForReadiness(_ client: ControlClient) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var delay = 0.025
        while ContinuousClock.now < deadline {
            do {
                let response = try await client.request(ControlRequest(command: "app.status"), timeout: 0.5, isMutation: false)
                if case .success = response { return }
            } catch let failure as ControlFailure where failure.code == .cancelled { throw failure }
            catch { }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { throw ControlFailure(.cancelled, "The command was interrupted.") }
            delay = min(delay * 2, 0.25)
        }
        throw ControlFailure(.appUnavailable, "Remora did not start its control listener within 10 seconds.", hint: "Open Remora and inspect its launch error.")
    }
}
