import AppKit
import RemoraControl

/// Launch Services owns app identity and startup. Only read-only probes are retried.
@MainActor
struct ApplicationClient {
    private var running: Bool {
        NSWorkspace.shared.runningApplications.contains { !$0.isTerminated && $0.bundleIdentifier == AppIdentity.current.bundleIdentifier }
    }

    func request(_ request: ControlRequest, launch: Bool, timeout: Double) async throws -> ControlResponse {
        let client = ControlClient(endpoint: ControlEndpoint())
        let wasRunning = running
        if !launch {
            do { return try await client.request(request, timeout: timeout, isMutation: false) } catch let failure as ControlFailure
                where failure.code == .appUnavailable && !wasRunning
            {
                return .success(try .encoding(AppStatus(running: false)))
            }
        }
        try await prepare(client)
        let readOnly = request.command.hasSuffix(".list") || request.command.hasSuffix(".get") || ["wait", "session.displays"].contains(request.command)
        return try await client.request(request, timeout: timeout, isMutation: !readOnly)
    }

    func prepare(_ client: ControlClient) async throws {
        let wasRunning = running
        do {
            _ = try await client.request(ControlRequest(command: "app.status"), timeout: 1, isMutation: false)
        } catch let failure as ControlFailure where failure.code == .cancelled {
            throw failure
        } catch {
            if !wasRunning { try openApplication() }
            try await waitForReadiness(client)
        }
    }

    private func openApplication() throws {
        // The build gives the helper its app's bundle identifier plus .cli, so a helper outside its own app never launches another.
        guard Bundle.main.bundleIdentifier == AppIdentity.current.bundleIdentifier + ".cli" else {
            throw ControlFailure(.appUnavailable, "The helper could not find its containing Remora app.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = ["--cli-background"]
        // A second simultaneous CLI launch must not send a window-opening reopen event.
        configuration.appleEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        NSWorkspace.shared.openApplication(at: AppIdentity.current.app, configuration: configuration, completionHandler: nil)
    }

    private func waitForReadiness(_ client: ControlClient) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var delay = 0.025
        while ContinuousClock.now < deadline {
            do {
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let seconds = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
                let response = try await client.request(ControlRequest(command: "app.status"), timeout: min(0.5, seconds), isMutation: false)
                if case .success = response { return }
            } catch let failure as ControlFailure where failure.code == .cancelled { throw failure } catch {}
            do {
                try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .seconds(delay))), clock: .continuous)
            } catch { throw ControlFailure(.cancelled, "The command was interrupted.") }
            delay = min(delay * 2, 0.25)
        }
        throw ControlFailure(.appUnavailable, "\(AppIdentity.current.name) did not start its control listener within 10 seconds.")
    }
}
