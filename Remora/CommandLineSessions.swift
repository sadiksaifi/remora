import AppKit
import RemoraControl
import RemoraCore

extension CommandLineController {
    func resolveSession(_ target: String?) throws -> SessionViewController {
        let candidates = sessions.tabs.compactMap { sessions.session(for: $0.id) }
        guard let target else {
            guard candidates.count == 1, let only = candidates.first else {
                throw ControlFailure(.sessionRequired, "Choose a session.")
            }
            return only
        }
        if let id = UUID(uuidString: target) {
            guard let session = candidates.first(where: { $0.attemptID == id }) else {
                throw ControlFailure(.sessionEnded, "The session attempt has ended or was replaced.")
            }
            return session
        }
        let matches = candidates.filter { $0.connection.name.caseInsensitiveCompare(target) == .orderedSame }
        guard let session = matches.first else { throw ControlFailure(.notFound, "Session not found.") }
        guard matches.count == 1 else { throw ControlFailure(.ambiguousTarget, "Several sessions have that name.") }
        return session
    }

    func sessionInfo(_ session: SessionViewController) -> ControlValue {
        let state: String
        var reason: ControlValue = .null
        switch session.state {
        case .connecting: state = "connecting"
        case .awaitingCredentials: state = "awaitingCredentials"
        case .awaitingTrust: state = "awaitingTrust"
        case .connected: state = "connected"
        case .reconnecting: state = "reconnecting"
        case .disconnected(let failure):
            state = "disconnected"
            reason = failure.map { .string($0.description) } ?? .null
        }
        let size = session.desktopSize ?? session.frameSize
        var fields: [String: ControlValue] = [
            "session": .string(session.attemptID.uuidString), "connection": .string(session.connection.id.uuidString),
            "name": .string(session.connection.name), "host": .string(session.attemptConnection.host),
            "port": .number(Double(session.attemptConnection.port)), "state": .string(state), "reason": reason,
            "control": .string(session.control.state.rawValue),
            "observationRequired": .bool(session.control.observationRequired),
            "controlTransferring": .bool(session.control.isTransferring),
            "startedBy": .string(session.startedBy), "dynamicResize": .bool(session.supportsDynamicResize),
            "desktop": size.map { .array([.number(Double($0.width)), .number(Double($0.height))]) } ?? .null,
            "hasFrame": .bool(session.frameSize != nil && session.frameRevision > 0 && displayIsReady(session)),
            "frame": .number(Double(session.frameRevision)),
            "recording": recordingInfo(session),
            "sizing": .string((session.attemptResolution ?? session.attemptConnection.resolution) == .fitToWindow ? "fit" : "fixed"),
            "prompt": session.pendingPrompt.map { .string($0.id.uuidString) } ?? .null,
        ]
        fields.merge(displayFields(session)) { _, display in display }
        return .object(fields)
    }

    func displayIsReady(_ session: SessionViewController) -> Bool {
        guard let state = session.inputBackend?.displays else { return true }
        return state.displays.isEmpty || state.isReady
    }

    func requireDisplayReady(_ session: SessionViewController) throws {
        guard displayIsReady(session) else {
            throw ControlFailure(.displayNotReady, "The selected display has no complete picture yet.")
        }
    }

    private func displayFields(_ session: SessionViewController) -> [String: ControlValue] {
        let state = session.inputBackend?.displays ?? SessionDisplays()
        return [
            "displays": .array(
                state.displays.enumerated().map { index, display in
                    .object([
                        "display": .number(Double(display.id)), "number": .number(Double(index + 1)),
                        "main": .bool(display.isMain),
                        "origin": .array([.number(Double(display.x)), .number(Double(display.y))]),
                        "size": .array([.number(Double(display.size.width)), .number(Double(display.size.height))]),
                    ])
                }),
            "selectedDisplay": state.selectedID.map { .number(Double($0)) } ?? .null,
            "pendingDisplay": state.pendingID.map { .number(Double($0)) } ?? .null,
            "displayReady": .bool(session.isConnected && (state.displays.isEmpty || state.isReady)),
        ]
    }

    func promptInfo(_ session: SessionViewController) -> ControlValue? {
        guard let prompt = session.pendingPrompt else { return nil }
        var fields: [String: ControlValue] = [
            "prompt": .string(prompt.id.uuidString), "session": .string(session.attemptID.uuidString),
            "actions": .array([.string("connect"), .string("cancel")]),
        ]
        switch prompt {
        case .credentials(_, let challenge):
            fields["kind"] = .string("credentials")
            fields["username"] = .string(session.credentialDraft?.username ?? challenge.username)
            fields["domain"] = .string(session.credentialDraft?.domain ?? challenge.domain)
            fields["fields"] = .array(
                (challenge.fields == .password
                    ? ["password"] : session.connection.kind == .rdp ? ["username", "domain", "password"] : ["username", "password"]).map(ControlValue.string))
            fields["reason"] = .string(challenge.reason == .missing ? "missing" : "rejected")
            fields["remember"] = .bool(session.credentialDraft?.remember ?? true)
            fields["hasPassword"] = .bool(!(session.credentialDraft?.password.isEmpty ?? true))
        case .certificate(_, let challenge):
            fields["kind"] = .string("certificate")
            fields["host"] = .string(challenge.host)
            fields["port"] = .number(Double(challenge.port))
            fields["subject"] = .string(challenge.subject)
            fields["issuer"] = .string(challenge.issuer)
            fields["fingerprint"] = .string(challenge.fingerprint)
            switch challenge.status {
            case .new: fields["status"] = .string("new")
            case .changed(let previous):
                fields["status"] = .string("changed")
                fields["previousFingerprint"] = .string(previous)
            }
        }
        return .object(fields)
    }

    private func promptSession(_ target: String) throws -> SessionViewController {
        guard let id = UUID(uuidString: target) else { throw ControlFailure(.invalidArgument, "A prompt ID must be a UUID.") }
        if let session = sessions.tabs.compactMap({ sessions.session(for: $0.id) }).first(where: { $0.pendingPrompt?.id == id }) { return session }
        if sessions.resolvedPrompts.contains(id) { throw ControlFailure(.promptResolved, "This prompt was already resolved.") }
        throw ControlFailure(.notFound, "Prompt not found.")
    }

    func promptRequired(_ session: SessionViewController) throws {
        if let prompt = session.pendingPrompt {
            throw ControlFailure(
                .promptRequired, "Session \(session.attemptID) requires prompt \(prompt.id).",
                details: .object(["prompt": .string(prompt.id.uuidString), "session": .string(session.attemptID.uuidString)]))
        }
    }

    /// Only command waiters poll. An idle app has no timer or frame demand from this adapter.
    func waitFor(
        _ session: SessionViewController, id: UUID, timeout: Double,
        disconnected: Bool = false, predicate: () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced.")
            }
            if try predicate() { return }
            try promptRequired(session)
            if !disconnected, case .disconnected(let reason) = session.state {
                throw ControlFailure(.backendFailed, reason?.description ?? "The session disconnected.")
            }
            guard ContinuousClock.now < deadline else {
                throw ControlFailure(
                    .timeout, "The session did not reach the requested state before the deadline.",
                    hint: "Wait again, or inspect `remora session get`.")
            }
            do { try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(25))), clock: .continuous) } catch {
                throw ControlFailure(.cancelled, "The command was interrupted.")
            }
        }
    }

    /// Keep demand through a repaint burst, but use the newest frame when the budget ends.
    func waitForSettledFrame(_ session: SessionViewController, id: UUID, deadline: TimeInterval) async throws {
        var firstFrameAt: TimeInterval?
        do {
            try await waitFor(session, id: id, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) {
                guard session.state == .connected, session.hasFreshFrame, displayIsReady(session),
                    let arrival = session.lastFrameArrival
                else { return false }
                let now = ProcessInfo.processInfo.systemUptime
                if firstFrameAt == nil { firstFrameAt = now }
                return now >= min(arrival + 0.25, firstFrameAt! + 2, deadline)
            }
        } catch let failure as ControlFailure where failure.code == .timeout {
            throw ControlFailure(.frameTimeout, "No fresh desktop frame arrived before the deadline.")
        }
    }

    /// A Windows server draws black frames while it attaches a new session, so the first `connect` to wait
    /// on an attempt gives a black frame three seconds to give way to the desktop. A desktop that really is
    /// black costs that wait once.
    private func waitForDesktop(_ session: SessionViewController, id: UUID, deadline: TimeInterval) async throws {
        try await waitForSettledFrame(session, id: id, deadline: deadline)
        guard !session.desktopSeen else { return }
        let patience = min(deadline, ProcessInfo.processInfo.systemUptime + 3)
        var wasBlank = false
        while ProcessInfo.processInfo.systemUptime < patience {
            let checked = session.frameRevision
            guard await session.showsBlankFrame() else { break }
            wasBlank = true
            do {
                try await waitFor(session, id: id, timeout: max(0, patience - ProcessInfo.processInfo.systemUptime)) { session.frameRevision != checked }
            } catch let failure as ControlFailure where failure.code == .timeout {
                break
            }
        }
        // The check suspends, so the session may have ended or been replaced meanwhile. Only a desktop that
        // replaced black frames is still painting.
        if wasBlank {
            try await waitForSettledFrame(session, id: id, deadline: deadline)
        } else {
            try await waitFor(session, id: id, timeout: 0) { session.state == .connected }
        }
        session.desktopSeen = true
    }

    func handleSession(_ request: ControlRequest) async throws -> ControlValue {
        let timeout = request.timeout ?? (request.command == "connect" ? 45 : 10)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        switch request.command {
        case "prompt.list":
            try request.validateArguments([])
            return .array(sessions.tabs.compactMap { sessions.session(for: $0.id).flatMap(promptInfo) })
        case "prompt.get", "prompt.respond":
            try request.validateArguments(
                request.command == "prompt.get" ? ["prompt"] : ["prompt", "action", "username", "domain", "remember", "password", "clearPassword"])
            let target = try request.string("prompt", required: true)!
            let session = try promptSession(target)
            if request.command == "prompt.get" { return promptInfo(session)! }
            let action = try request.string("action", required: true)!
            guard ["connect", "cancel"].contains(action) else { throw ControlFailure(.invalidArgument, "Action must be connect or cancel.") }
            let hasEdits = !Set(request.arguments.keys).isDisjoint(with: ["username", "domain", "remember", "password", "clearPassword"])
            guard let prompt = session.pendingPrompt else { throw ControlFailure(.promptResolved, "This prompt was already resolved.") }
            if action == "cancel"
                || {
                    if case .certificate = prompt { return true }
                    return false
                }()
            {
                guard !hasEdits else { throw ControlFailure(.invalidArgument, "Certificate and cancel answers accept no credential fields.") }
                try session.respondToPrompt(prompt.id, credentials: nil, trust: action == "connect")
            } else if case .credentials(_, let challenge) = prompt {
                let remember = try request.string("remember")
                guard remember == nil || remember == "true" || remember == "false" else {
                    throw ControlFailure(.invalidArgument, "remember must be true or false.")
                }
                let password = try request.string("password")
                let clear = try request.flag("clearPassword")
                guard password == nil || !clear else { throw ControlFailure(.invalidArgument, "Choose a password or clearPassword.") }
                let answer = try SessionCredentials(
                    username: request.string("username") ?? session.credentialDraft?.username ?? challenge.username,
                    domain: request.string("domain") ?? session.credentialDraft?.domain ?? challenge.domain,
                    password: clear ? "" : password ?? session.credentialDraft?.password ?? "")
                try session.respondToPrompt(
                    prompt.id, credentials: answer, remember: remember.map { $0 == "true" } ?? session.credentialDraft?.remember ?? true)
            }
            return .object(["prompt": .string(prompt.id.uuidString), "resolved": .bool(true), "session": .string(session.attemptID.uuidString)])
        case "session.list":
            try request.validateArguments([])
            return .array(sessions.tabs.compactMap { sessions.session(for: $0.id).map(sessionInfo) })
        case "connect":
            try request.validateArguments(["connection", "background", "resolution", "noWait"])
            let connection = try resolveConnection(request.string("connection", required: true)!)
            let background = try request.flag("background")
            let noWait = try request.flag("noWait")
            let resolution = try request.string("resolution").map { try parseResolution($0) }
            if let existing = sessions.session(for: connection.id), existing.state.isLive, let resolution,
                resolution != (existing.attemptResolution ?? existing.attemptConnection.resolution)
            {
                throw ControlFailure(.sessionExists, "An active session uses a different resolution.")
            }
            let existing = sessions.session(for: connection.id)
            // Starting an ended session again is input in all but name, so the user's Take Over or Stop binds it too.
            if let existing, !existing.state.isLive { try existing.checkUserHold() }
            let started = sessions.open(connection, select: !background, agent: request.agent ?? "remora CLI", resolution: resolution)
            let session = sessions.session(for: connection.id)!
            func result() -> ControlValue {
                guard case .object(var fields) = sessionInfo(session) else { return .null }
                fields["reused"] = .bool(existing != nil)
                return .object(fields)
            }
            do {
                if started {
                    do { try connectionStore.markConnected(id: connection.id) } catch {
                        throw ControlFailure(.storeFailed, "Session started, but its last-connected date could not be saved.")
                    }
                }
                if !background { show(nil) }
                try promptRequired(session)
                if noWait { return result() }
                session.addFrameDemand()
                defer { session.removeFrameDemand() }
                try await waitForDesktop(session, id: session.attemptID, deadline: deadline)
                return result()
            } catch let failure as ControlFailure {
                // The session exists by now, so a failed connect still says which one and whether its tab was already there.
                var details: [String: ControlValue] = if case .object(let fields) = failure.details { fields } else { [:] }
                details["session"] = .string(session.attemptID.uuidString)
                details["reused"] = .bool(existing != nil)
                throw ControlFailure(failure.code, failure.message, hint: failure.hint, details: .object(details))
            }
        default: break
        }
        if request.command == "session.release" {
            try request.validateArguments(["all"], sessionAllowed: true)
            let all = try request.flag("all")
            guard !all || request.session == nil else { throw ControlFailure(.invalidArgument, "Use --all without --session.") }
            let targets = all ? sessions.tabs.compactMap { sessions.session(for: $0.id) } : [try resolveSession(request.session)]
            var failure: Error?
            for session in targets {
                do { try await session.handoverAgentControl(.release) } catch { if failure == nil { failure = error } }
            }
            if let failure { throw failure }
            return .array(targets.map(sessionInfo))
        }
        let allowed: Set<String>
        switch request.command {
        case "session.get", "session.displays", "session.show", "session.disconnect", "session.close": allowed = []
        case "session.display": allowed = ["display"]
        case "session.resize": allowed = ["resolution"]
        case "wait": allowed = ["for"]
        default: throw ControlFailure(.unknownCommand, "Unknown session command.")
        }
        try request.validateArguments(allowed, sessionAllowed: true)
        let session = try resolveSession(request.session)
        let id = session.attemptID
        switch request.command {
        case "session.get": return sessionInfo(session)
        case "session.displays":
            var fields = displayFields(session)
            fields["session"] = .string(id.uuidString)
            return .object(fields)
        case "session.display":
            try session.checkUserHold()
            try promptRequired(session)
            guard session.isConnected, let backend = session.inputBackend else {
                throw ControlFailure(.notConnected, "The session is not connected.")
            }
            guard case .number(let number) = request.arguments["display"], number.isFinite,
                number.rounded() == number, number >= 0, number <= Double(UInt32.max)
            else { throw ControlFailure(.invalidArgument, "display must be a display ID from session displays.") }
            let display = UInt32(number)
            session.addFrameDemand()
            defer { session.removeFrameDemand() }
            switch session.selectDisplay(display) {
            case .success: break
            case .failure(.unsupported): throw ControlFailure(.unsupported, "This session does not support selecting a display.")
            case .failure(.unavailable): throw ControlFailure(.displayUnavailable, "The display is no longer available.")
            case .failure(.busy): throw ControlFailure(.displayNotReady, "Another display switch is in progress.")
            case .failure(.timedOut): throw ControlFailure(.frameTimeout, "The display switch timed out.")
            }
            try await waitFor(session, id: id, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) {
                let state = backend.displays
                guard state.displays.contains(where: { $0.id == display }) else {
                    throw ControlFailure(.displayUnavailable, "The display was disconnected during the switch.")
                }
                if state.isReady, state.selectedID == display { return session.hasFreshFrame }
                guard state.pendingID != nil else {
                    throw ControlFailure(.displayNotReady, "The requested display did not become ready. Inspect its current state before retrying.")
                }
                return false
            }
        case "session.show":
            sessions.select(session.connection.id)
            show(nil)
        case "session.disconnect", "session.close":
            if request.command == "session.close" { try session.checkUserHold() }
            session.disconnectSession()
            try await waitFor(session, id: id, timeout: timeout, disconnected: true) { !session.state.isLive }
            if case .failure(let failure) = await session.stopRecording() { throw ControlFailure(.captureFailed, failure.localizedDescription) }
            guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced.")
            }
            if request.command == "session.close" { sessions.close(session.connection.id) }
        case "session.resize":
            let resolution = try parseResolution(request.string("resolution", required: true)!)
            try session.resize(resolution)
            if case .fixed(let width, let height) = resolution, session.desktopSize != .init(width: width, height: height) {
                session.addFrameDemand()
                defer { session.removeFrameDemand() }
                try await waitFor(session, id: id, timeout: timeout) {
                    if session.connection.kind == .vnc, session.isConnected, !session.supportsDynamicResize {
                        throw ControlFailure(.unsupported, "The VNC server denied desktop resizing.")
                    }
                    return session.desktopSize == .init(width: width, height: height)
                }
            }
        case "wait":
            let target = try request.string("for", required: true)!
            if target == "resumed" {
                let revision = session.control.resumeRevision
                try await waitFor(session, id: id, timeout: timeout) {
                    if session.control.resumeRevision > revision { return true }
                    if session.control.state == .stopped { throw SessionViewController.agentStopped }
                    return session.control.state == .active && !session.control.isTransferring
                }
                return sessionInfo(session)
            }
            guard ["connected", "disconnected"].contains(target) else { throw ControlFailure(.invalidArgument, "Wait supports connected or disconnected.") }
            if target == "connected" { session.addFrameDemand() }
            defer { if target == "connected" { session.removeFrameDemand() } }
            try await waitFor(session, id: id, timeout: timeout, disconnected: target == "disconnected") {
                target == "connected" ? session.state == .connected && session.hasFreshFrame && displayIsReady(session) : !session.state.isLive
            }
        default: break
        }
        return sessionInfo(session)
    }
}
