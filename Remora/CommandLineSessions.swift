import AppKit
import RemoraControl
import RemoraCore

extension CommandLineController {
    func resolveSession(_ target: String?) throws -> SessionViewController {
        let candidates = sessions.tabs.compactMap { sessions.session(for: $0.id) }
        guard let target else {
            guard candidates.count == 1, let only = candidates.first else {
                throw ControlFailure(.sessionRequired, "Choose a session.", hint: "Use session list and --session S.")
            }
            return only
        }
        if let id = UUID(uuidString: target) {
            guard let session = candidates.first(where: { $0.attemptID == id }) else {
                throw ControlFailure(.sessionEnded, "The session attempt has ended or was replaced.", hint: "Inspect session list for its current ID.")
            }
            return session
        }
        let matches = candidates.filter { $0.connection.name.caseInsensitiveCompare(target) == .orderedSame }
        guard let session = matches.first else { throw ControlFailure(.notFound, "Session not found.") }
        guard matches.count == 1 else { throw ControlFailure(.ambiguousTarget, "Several sessions have that name.", hint: "Use a session UUID.") }
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
        return .object([
            "session": .string(session.attemptID.uuidString), "connection": .string(session.connection.id.uuidString),
            "name": .string(session.connection.name), "host": .string(session.attemptConnection.host),
            "port": .number(Double(session.attemptConnection.port)), "state": .string(state), "reason": reason,
            "control": .string(session.control.state.rawValue),
            "observationRequired": .bool(session.control.observationRequired),
            "controlTransferring": .bool(session.control.isTransferring),
            "startedBy": .string(session.startedBy), "dynamicResize": .bool(session.supportsDynamicResize),
            "desktop": size.map { .array([.number(Double($0.width)), .number(Double($0.height))]) } ?? .null,
            "hasFrame": .bool(session.frameSize != nil && session.frameRevision > 0),
            "frame": .number(Double(session.frameRevision)),
            "recording": recordingInfo(session),
            "sizing": .string((session.attemptResolution ?? session.attemptConnection.resolution) == .fitToWindow ? "fit" : "fixed"),
            "prompt": session.pendingPrompt.map { .string($0.id.uuidString) } ?? .null
        ])
    }

    func promptInfo(_ session: SessionViewController) -> ControlValue? {
        guard let prompt = session.pendingPrompt else { return nil }
        var fields: [String: ControlValue] = ["prompt": .string(prompt.id.uuidString), "session": .string(session.attemptID.uuidString),
            "actions": .array([.string("connect"), .string("cancel")])]
        switch prompt {
        case .credentials(_, let challenge):
            fields["kind"] = .string("credentials")
            fields["username"] = .string(session.credentialDraft?.username ?? challenge.username)
            fields["domain"] = .string(session.credentialDraft?.domain ?? challenge.domain)
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
            case .changed(let previous): fields["status"] = .string("changed"); fields["previousFingerprint"] = .string(previous)
            }
        }
        return .object(fields)
    }

    private func promptSession(_ target: String) throws -> SessionViewController {
        guard let id = UUID(uuidString: target) else { throw ControlFailure(.invalidArgument, "A prompt ID must be a UUID.") }
        if let session = sessions.tabs.compactMap({ sessions.session(for: $0.id) }).first(where: { $0.pendingPrompt?.id == id }) { return session }
        if sessions.resolvedPrompts.contains(id) { throw ControlFailure(.promptResolved, "This prompt was already resolved.", hint: "Inspect prompt list.") }
        throw ControlFailure(.notFound, "Prompt not found.", hint: "Inspect prompt list.")
    }

    func promptRequired(_ session: SessionViewController) throws {
        if let prompt = session.pendingPrompt {
            throw ControlFailure(.promptRequired, "Session \(session.attemptID) requires prompt \(prompt.id).", hint: "Run remora prompt get \(prompt.id) and remora prompt respond \(prompt.id) connect|cancel.", details: .object(["prompt": .string(prompt.id.uuidString), "session": .string(session.attemptID.uuidString)]))
        }
    }

    /// Only command waiters poll. An idle app has no timer or frame demand from this adapter.
    func waitFor(_ session: SessionViewController, id: UUID, timeout: Double,
                         disconnected: Bool = false, predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced.", hint: "Inspect session list.")
            }
            if predicate() { return }
            try promptRequired(session)
            if !disconnected, case .disconnected(let reason) = session.state {
                throw ControlFailure(.backendFailed, reason?.description ?? "The session disconnected.", hint: "Inspect session get before reconnecting.")
            }
            guard ContinuousClock.now < deadline else { throw ControlFailure(.timeout, "The session did not reach the requested state before the deadline.") }
            do { try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(25))), clock: .continuous) }
            catch { throw ControlFailure(.cancelled, "The command was interrupted.") }
        }
    }

    func handleSession(_ request: ControlRequest) async throws -> ControlValue {
        let timeout = request.timeout ?? (["connect", "session.reconnect"].contains(request.command) ? 30 : 10)
        switch request.command {
        case "prompt.list":
            try request.validateArguments([])
            return .array(sessions.tabs.compactMap { sessions.session(for: $0.id).flatMap(promptInfo) })
        case "prompt.get", "prompt.respond":
            try request.validateArguments(request.command == "prompt.get" ? ["prompt"] : ["prompt", "action", "username", "domain", "remember", "password", "clearPassword"])
            let target = try request.string("prompt", required: true)!
            let session = try promptSession(target)
            if request.command == "prompt.get" { return promptInfo(session)! }
            let action = try request.string("action", required: true)!
            guard ["connect", "cancel"].contains(action) else { throw ControlFailure(.invalidArgument, "Action must be connect or cancel.") }
            let hasEdits = !Set(request.arguments.keys).isDisjoint(with: ["username", "domain", "remember", "password", "clearPassword"])
            guard let prompt = session.pendingPrompt else { throw ControlFailure(.promptResolved, "This prompt was already resolved.") }
            if action == "cancel" || { if case .certificate = prompt { return true }; return false }() {
                guard !hasEdits else { throw ControlFailure(.invalidArgument, "Certificate and cancel answers accept no credential fields.") }
                try session.respondToPrompt(prompt.id, credentials: nil, trust: action == "connect")
            } else if case .credentials(_, let challenge) = prompt {
                let remember = try request.string("remember")
                guard remember == nil || remember == "true" || remember == "false" else { throw ControlFailure(.invalidArgument, "remember must be true or false.") }
                let password = try request.string("password")
                let clear = try request.flag("clearPassword")
                guard password == nil || !clear else { throw ControlFailure(.invalidArgument, "Choose a password or clearPassword.") }
                let answer = try SessionCredentials(username: request.string("username") ?? session.credentialDraft?.username ?? challenge.username,
                    domain: request.string("domain") ?? session.credentialDraft?.domain ?? challenge.domain,
                    password: clear ? "" : password ?? session.credentialDraft?.password ?? "")
                try session.respondToPrompt(prompt.id, credentials: answer, remember: remember.map { $0 == "true" } ?? session.credentialDraft?.remember ?? true)
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
               resolution != (existing.attemptResolution ?? existing.attemptConnection.resolution) {
                throw ControlFailure(.sessionExists, "An active session uses a different resolution.", hint: "Inspect it or disconnect explicitly.")
            }
            let started = sessions.open(connection, select: !background, commandLine: true, resolution: resolution)
            if started {
                do { try connectionStore.markConnected(id: connection.id) }
                catch { throw ControlFailure(.storeFailed, "Session started, but its last-connected date could not be saved.", hint: "Inspect session list before retrying.") }
            }
            let session = sessions.session(for: connection.id)!
            if !background { show(nil) }
            try promptRequired(session)
            if noWait { return sessionInfo(session) }
            session.addFrameDemand()
            defer { session.removeFrameDemand() }
            try await waitFor(session, id: session.attemptID, timeout: timeout) { session.state == .connected && session.frameSize != nil }
            return sessionInfo(session)
        default: break
        }
        if request.command == "session.stop" {
            try request.validateArguments(["all"], sessionAllowed: true)
            let all = try request.flag("all")
            guard !all || request.session == nil else { throw ControlFailure(.invalidArgument, "Use --all without --session.") }
            let targets = all ? sessions.tabs.compactMap { sessions.session(for: $0.id) } : [try resolveSession(request.session)]
            for session in targets { try await session.handoverAgentControl(stopping: true, by: "cli") }
            return .array(targets.map(sessionInfo))
        }
        let allowed: Set<String>
        switch request.command {
        case "session.get", "session.show", "session.disconnect", "session.close", "session.resume": allowed = []
        case "session.reconnect": allowed = ["noWait"]
        case "session.resize": allowed = ["resolution"]
        case "wait": allowed = ["for"]
        default: throw ControlFailure(.unknownCommand, "Unknown session command.")
        }
        try request.validateArguments(allowed, sessionAllowed: true)
        let session = try resolveSession(request.session)
        let id = session.attemptID
        switch request.command {
        case "session.get": return sessionInfo(session)
        case "session.resume": try session.resumeAgentControl(by: "cli")
        case "session.show": sessions.select(session.connection.id); show(nil)
        case "session.disconnect", "session.close":
            session.disconnectSession()
            try await waitFor(session, id: id, timeout: timeout, disconnected: true) { !session.state.isLive }
            if case .failure(let failure) = await session.stopRecording() { throw ControlFailure(.captureFailed, failure.localizedDescription) }
            guard session.attemptID == id, sessions.session(for: session.connection.id) === session else {
                throw ControlFailure(.sessionEnded, "The session attempt was closed or replaced.", hint: "Inspect session list.")
            }
            if request.command == "session.close" { sessions.close(session.connection.id) }
        case "session.reconnect":
            let noWait = try request.flag("noWait")
            guard !session.state.isLive else { throw ControlFailure(.sessionExists, "Disconnect this session before reconnecting.") }
            guard let connection = connectionStore.connections.first(where: { $0.id == session.connection.id }) else {
                throw ControlFailure(.connectionDeleted, "The saved connection was deleted.", hint: "Create a new connection explicitly.")
            }
            session.update(connection)
            session.reconnect()
            if !noWait {
                session.addFrameDemand()
                defer { session.removeFrameDemand() }
                try await waitFor(session, id: session.attemptID, timeout: timeout) { session.state == .connected && session.frameSize != nil }
            }
        case "session.resize":
            let resolution = try parseResolution(request.string("resolution", required: true)!)
            try session.resize(resolution)
            if case .fixed(let width, let height) = resolution, session.desktopSize != .init(width: width, height: height) {
                session.addFrameDemand()
                defer { session.removeFrameDemand() }
                try await waitFor(session, id: id, timeout: timeout) {
                    session.desktopSize == .init(width: width, height: height)
                }
            }
        case "wait":
            let target = try request.string("for", required: true)!
            if target == "resumed" {
                let revision = session.control.resumeRevision
                try await waitFor(session, id: id, timeout: timeout) {
                    session.control.state == .active && !session.control.isTransferring || session.control.resumeRevision > revision
                }
                return sessionInfo(session)
            }
            guard ["connected", "disconnected"].contains(target) else { throw ControlFailure(.invalidArgument, "Wait supports connected or disconnected.") }
            try await waitFor(session, id: id, timeout: timeout, disconnected: target == "disconnected") {
                target == "connected" ? session.state == .connected : !session.state.isLive
            }
        default: break
        }
        return sessionInfo(session)
    }
}
