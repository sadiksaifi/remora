import CFreeRDPBridge
import CVNCBridge
import CryptoKit
import Foundation
import RemoraCore
import os

private let log = Logger(subsystem: "dev.sadiksaifi.Remora", category: "VNC")

/// One native VNC connection. The worker owns LibVNCClient, frame storage and
/// held input. The lock protects only admission, receipts, prompts and abort.
public final class VNCSession: AgentInputSession, @unchecked Sendable {
    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: SessionConfiguration
    private let frameSink: any FrameSink
    private let inputFeedback: @Sendable (InputSource, SessionInputFeedback) -> Void
    private let certificateStoreURL: URL
    private let isoKeyboard: Bool
    private let state = State()

    @MainActor
    public init(configuration: SessionConfiguration, frameSink: any FrameSink,
                inputFeedback: @escaping @Sendable (InputSource, SessionInputFeedback) -> Void = { _, _ in },
                certificateStoreURL: URL = URL.applicationSupportDirectory.appending(path: "Remora/VNC/certificates", directoryHint: .isDirectory)) {
        self.configuration = configuration
        self.frameSink = frameSink
        self.inputFeedback = inputFeedback
        self.certificateStoreURL = certificateStoreURL
        self.isoKeyboard = KeyboardType.isISO
        (events, continuation) = AsyncStream.makeStream()
    }

    public func connect() {
        state.lock.withLock {
            guard !state.started else { return }
            state.started = true
            state.networkDeadline = .now.advanced(by: .seconds(20))
            continuation.yield(.stateChanged(.connecting))
            let worker = Thread { [self] in run() }
            worker.name = "Remora VNC session"
            worker.start()
            // Covers TLS/auth loops as well as TCP. Prompts suspend this deadline.
            state.watchdog = Task.detached { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    let expired = state.lock.withLock {
                        !state.ended && state.networkDeadline.map { ContinuousClock.now >= $0 } == true
                    }
                    if expired { stop(.connectionTimedOut); return }
                }
            }
        }
    }

    public func disconnect() { stop(.cancelledByUser) }

    private func stop(_ reason: DisconnectReason) {
        state.lock.withLock {
            guard !state.ended, !state.stopping else { return }
            state.stopping = true
            state.reason = reason
            state.cancelChallenge?()
            if let handle = state.handle { rm_vnc_abort(handle) }
            if !state.started {
                state.started = true; state.ended = true
                continuation.yield(.stateChanged(.disconnected(reason)))
                continuation.finish()
            }
        }
    }

    public var supportsDynamicResize: Bool {
        state.lock.withLock { configuration.allowsDynamicResize && state.connected && !state.stopping && state.resizeSupported }
    }
    public var maximumResizeArea: UInt64? { supportsDynamicResize ? 67_108_864 : nil }
    public var inputCapabilities: AgentInputCapabilities {
        state.lock.withLock { state.connected && !state.stopping ? [.unicode, .horizontalWheel] : [] }
    }
    /// The actual negotiated security label, available after connection.
    public var negotiatedSecurity: String? { state.lock.withLock { state.security } }

    public func requestResize(_ size: DesktopSize, scale: Double) {
        guard configuration.allowsDynamicResize, (1...65535).contains(size.width), (1...65535).contains(size.height),
              UInt64(size.width) * UInt64(size.height) <= 67_108_864 else { return }
        state.lock.withLock {
            if state.connected, !state.stopping, state.resizeSupported { state.resize = size }
        }
    }

    public func setDisplayUpdatesEnabled(_ enabled: Bool) {
        state.lock.withLock {
            // LibVNCClient manages incremental requests; unsupported suppression
            // deliberately keeps updates flowing. Resuming requests a full redraw.
            if enabled, state.connected, !state.stopping { state.refresh = true }
        }
    }
    public func sendKey(_ key: KeyInput) { enqueue(.humanKey(key)) }
    public func sendPointer(position: RemotePoint, buttons: PointerButtons) { enqueue(.human(.pointer(position, PointerButtons(rawValue: buttons.rawValue & 7)))) }
    public func sendWheel(_ wheel: WheelInput) { enqueue(.human(.wheel(wheel))) }
    public func synchronize(locks: LockKeys) {
        // RFB has no portable lock-state synchronize message. Caps Lock key
        // pulses still travel through normal keyboard input.
    }
    public func releaseHumanInput() { enqueue(.releaseHuman) }
    public func setLocalClipboard(text: String) {
        guard text.utf8.count <= 1_048_576 else { clipboard(.failed); return }
        state.lock.withLock { if !state.stopping, !state.ended { state.clipboard = text } }
    }

    public func beginAgentInput() -> (any AgentInputRequest)? {
        state.lock.withLock {
            guard state.connected, !state.stopping, state.agent == nil else { return nil }
            state.nextAgent &+= 1
            let id = state.nextAgent
            state.agent = id; state.agentCancelled = false
            return Request(session: self, id: id)
        }
    }

    private func enqueue(_ command: Command) {
        state.lock.withLock {
            guard state.connected, !state.stopping else { return }
            guard state.commands.count < 4096 else {
                state.stopping = true
                state.reason = .protocolError("The VNC input queue overflowed.")
                if let handle = state.handle { rm_vnc_abort(handle) }
                return
            }
            state.commands.append(command)
        }
    }

    private func submit(_ event: AgentInputEvent?, id: UInt64) -> Receipt? {
        state.lock.withLock {
            guard state.connected, !state.stopping, state.agent == id,
                  event == nil || (!state.agentCancelled && !state.agentPending) else { return nil }
            let receipt = Receipt()
            state.receipts.append(receipt)
            if event != nil { state.agentPending = true }
            state.commands.append(.agent(id, event, receipt))
            return receipt
        }
    }

    private func cancel(_ id: UInt64) {
        state.lock.withLock { if state.agent == id { state.agentCancelled = true } }
    }

    private func run() {
        autoreleasepool {
            var handle: OpaquePointer?
            defer {
                state.lock.withLock { state.connected = false; state.handle = nil }
                if let handle { rm_vnc_free(handle) }
                finish()
            }
            do {
                let pinURL = certificateStoreURL.appendingPathComponent(SHA256.hash(data: Data("\(configuration.host.lowercased()):\(configuration.port)".utf8)).map { String(format: "%02x", $0) }.joined())
                let pin: Data?
                do { pin = try Data(contentsOf: pinURL) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { pin = nil }
                if let pin, pin.count != 32 { throw Failure("The saved VNC certificate fingerprint is invalid.") }
                state.lock.withLock { state.pin = pin; state.pinURL = pinURL }
                guard !state.lock.withLock({ state.stopping }) else { return }
                guard let created = configuration.host.withCString({ rm_vnc_create($0, configuration.port, callbacks(), Unmanaged.passUnretained(self).toOpaque()) }) else {
                    throw Failure("LibVNCClient allocation failed.")
                }
                handle = created
                state.lock.withLock {
                    state.handle = created
                    if state.stopping { rm_vnc_abort(created) }
                }
                guard rm_vnc_connect(created) else {
                    let reason: DisconnectReason = switch rm_vnc_error(created) {
                    case 1: .hostNotFound
                    case 2: .connectionRefused
                    case 3: .connectionTimedOut
                    case 4: .authenticationFailed
                    case 5: .certificateRejected
                    default: .protocolError("VNC negotiation failed. Supported security: VeNCrypt X509None/X509VNC/X509Plain, classic VNC, None, and ARD. RSA-AES and anonymous TLS are unsupported.")
                    }
                    state.lock.withLock { if state.reason == nil { state.reason = reason } }
                    return
                }
                let security = String(cString: rm_vnc_security(created))
                log.info("Connected using \(security, privacy: .public)")
                state.lock.withLock { state.connected = true; state.networkDeadline = nil; state.security = security }
                emit(.stateChanged(.connected))
                clipboard(.unknown)
                let wire = Transport(handle: created)
                var input = VNCInputState()
                while !state.lock.withLock({ state.stopping }) {
                    let commands = state.lock.withLock {
                        let commands = state.commands
                        state.commands.removeAll(keepingCapacity: true)
                        return commands
                    }
                    var failed = false
                    for command in commands {
                        guard !state.lock.withLock({ state.stopping }) else { break }
                        switch command {
                        case .humanKey(let key):
                            let scan = rm_rdp_scancode(key.keyCode, isoKeyboard)
                            failed = !input.humanKey(scan: scan, down: key.isDown, characters: key.characters, wire: wire)
                            if !failed { inputFeedback(.human, .key(scancode: scan, down: key.isDown, characters: key.characters)) }
                        case .human(let event):
                            // The UI may forward extra buttons without querying capabilities.
                            if case .pointer(_, let buttons) = event, !buttons.intersection([.back, .forward]).isEmpty { continue }
                            failed = !input.apply(event, source: .human, wire: wire)
                            if !failed { feedback(event, source: .human) }
                        case .releaseHuman:
                            failed = !input.release(.human, wire: wire)
                            if !failed { inputFeedback(.human, .release) }
                        case .agent(let id, let event, let receipt):
                            let admitted = state.lock.withLock { state.agent == id && (event == nil || !state.agentCancelled) }
                            if !admitted {
                                receipt.resolve(.cancelled)
                                state.lock.withLock { state.receipts.removeAll { $0 === receipt } }
                                continue
                            }
                            let accepted = event.map { input.apply($0, source: .agent, wire: wire) } ?? input.release(.agent, wire: wire)
                            state.lock.withLock {
                                if state.agent == id {
                                    state.agentPending = false
                                    if event == nil { state.agent = nil }
                                }
                            }
                            failed = !accepted
                            if accepted {
                                if let event { feedback(event, source: .agent) }
                                else { inputFeedback(.agent, .release) }
                            }
                            receipt.resolve(accepted ? nil : .submissionFailed)
                            state.lock.withLock { state.receipts.removeAll { $0 === receipt } }
                        }
                        if failed { break }
                    }
                    if failed { throw Failure("The VNC input submission failed. The transport was closed.") }
                    let pending = state.lock.withLock {
                        let pending = (state.clipboard, state.resize, state.refresh)
                        state.clipboard = nil; state.resize = nil; state.refresh = false
                        return pending
                    }
                    if let text = pending.0 {
                        let utf8 = rm_vnc_clipboard_utf8(created)
                        if let data = text.data(using: utf8 ? .utf8 : .isoLatin1, allowLossyConversion: false) {
                            let accepted = data.withUnsafeBytes { raw in rm_vnc_clipboard(created, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), utf8) }
                            if !accepted { throw Failure("The VNC clipboard submission failed.") }
                            clipboard(.offered(text))
                        } else { clipboard(.failed) }
                    }
                    if let size = pending.1, !rm_vnc_resize(created, UInt16(size.width), UInt16(size.height)) { throw Failure("The VNC resize submission failed.") }
                    if pending.2, !rm_vnc_refresh(created) { throw Failure("The VNC framebuffer refresh failed.") }
                    guard rm_vnc_step(created) else {
                        state.lock.withLock { if state.reason == nil { state.reason = .serverEndedSession("The VNC connection closed or a framebuffer read failed.") } }
                        break
                    }
                    let resize = configuration.allowsDynamicResize && rm_vnc_resize_supported(created)
                    let changed = state.lock.withLock {
                        let changed = state.resizeSupported != resize
                        state.resizeSupported = resize
                        return changed
                    }
                    if changed { emit(.dynamicResizeChanged(resize)) }
                }
            } catch {
                state.lock.withLock { if state.reason == nil { state.reason = .protocolError(error.localizedDescription) } }
            }
        }
    }

    private func finish() {
        state.lock.withLock {
            guard !state.ended else { return }
            state.ended = true; state.connected = false; state.networkDeadline = nil
            state.cancelChallenge = nil
            state.watchdog?.cancel(); state.watchdog = nil
            for receipt in state.receipts { receipt.resolve(.sessionEnded) }
            state.receipts.removeAll()
            state.commands.removeAll()
            continuation.yield(.stateChanged(.disconnected(state.reason)))
            continuation.finish()
        }
        inputFeedback(.human, .release); inputFeedback(.agent, .release)
    }

    private func emit(_ event: SessionEvent) {
        state.lock.withLock { if !state.ended, !state.stopping { continuation.yield(event) } }
    }
    private func clipboard(_ status: RemoteClipboard.Status) {
        state.lock.withLock {
            guard !state.ended, !state.stopping else { return }
            state.clipboardRevision &+= 1
            continuation.yield(.clipboardChanged(revision: state.clipboardRevision, status: status))
        }
    }
    private func feedback(_ event: AgentInputEvent, source: InputSource) {
        switch event {
        case .key(let key, let down): inputFeedback(source, .key(scancode: key.scancode, down: down))
        case .pointer(let point, let buttons): inputFeedback(source, .pointer(point, buttons))
        case .unicode(let scalar): inputFeedback(source, .text(String(scalar)))
        case .pause: inputFeedback(source, .key(scancode: 0x146, down: true))
        case .wheel: break
        }
    }

    private func challenge<Answer: Sendable>(cancel: Answer, events make: (SessionResponder<Answer>) -> [SessionEvent]) -> Answer {
        let wait = Wait<Answer>()
        let responder = SessionResponder<Answer> { wait.resolve($0) }
        state.lock.withLock {
            if state.stopping { responder.respond(cancel) }
            else {
                state.networkDeadline = nil
                state.cancelChallenge = { responder.respond(cancel) }
                make(responder).forEach { continuation.yield($0) }
            }
        }
        let answer = wait.answer()
        state.lock.withLock {
            state.cancelChallenge = nil
            state.networkDeadline = .now.advanced(by: .seconds(20))
        }
        return answer
    }

    private func callbacks() -> RMVNCCallbacks {
        var cb = RMVNCCallbacks()
        cb.size = { user, width, height, requested in owner(user).emit(.desktopSizeChanged(.init(width: Int(width), height: Int(height)), requested: requested)) }
        cb.frame = { user, pixels, width, height, x, y, w, h in
            guard let pixels else { return }
            owner(user).frameSink.consume(.init(pixels: pixels, width: Int(width), height: Int(height), stride: Int(width)*4,
                dirtyRectangles: [.init(x: Int(x), y: Int(y), width: Int(w), height: Int(h))]))
        }
        cb.cursor = { user, pixels, width, height, x, y in
            guard width > 0, height > 0, let pixels, let x = UInt16(exactly: x), let y = UInt16(exactly: y) else { owner(user).emit(.cursorChanged(.hidden)); return }
            owner(user).emit(.cursorChanged(.image(pixels: Data(bytes: pixels, count: Int(width)*Int(height)*4), width: Int(width), height: Int(height), hotspot: .init(x: x, y: y))))
        }
        cb.clipboard = { user, text, length, utf8 in
            guard let text else { return }
            let data = Data(bytes: text, count: Int(length))
            let value = String(data: data, encoding: utf8 ? .utf8 : .isoLatin1)
            owner(user).clipboard(value.map(RemoteClipboard.Status.text) ?? .failed)
        }
        cb.credentials = { user, usernameRequired, newUsername, newPassword in
            let session = owner(user)
            let config = session.configuration
            let answer: SessionCredentials?
            if let password = config.password, !usernameRequired || !config.username.isEmpty {
                answer = .init(username: config.username, password: password)
            } else {
                answer = session.challenge(cancel: nil) { responder in
                    [.stateChanged(.awaitingCredentials), .credentialsChallenge(.init(username: config.username, domain: "", reason: .missing,
                        responder: responder, fields: usernameRequired ? .usernamePassword : .password))]
                }
            }
            guard let answer else { return false }
            let username = strdup(answer.username), password = strdup(answer.password)
            guard let username, let password else { free(username); free(password); return false }
            newUsername?.pointee = username; newPassword?.pointee = password
            session.emit(.stateChanged(.connecting))
            return true
        }
        cb.pin = { user, bytes in
            guard let bytes, let pin = owner(user).state.lock.withLock({ owner(user).state.pin }) else { return false }
            pin.copyBytes(to: bytes, count: 32)
            return true
        }
        cb.trust = { user, subject, bytes, length in
            let session = owner(user)
            guard let bytes, length == 32 else { return false }
            let pin = Data(bytes: bytes, count: length)
            let previous = session.state.lock.withLock { session.state.pin }
            let config = session.configuration
            let accepted: CertificateDecision = session.challenge(cancel: .reject) { responder in
                [.stateChanged(.awaitingTrust), .trustChallenge(.init(host: config.host, port: config.port,
                    subject: subject.map { String(cString: $0) } ?? "", issuer: "", fingerprint: fingerprint(pin),
                    status: previous.map { .changed(oldFingerprint: fingerprint($0)) } ?? .new, responder: responder))]
            }
            guard accepted == .trust, !session.state.lock.withLock({ session.state.stopping }) else { return false }
            do {
                guard let url = session.state.lock.withLock({ session.state.pinURL }) else { return false }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try pin.write(to: url, options: [.atomic])
                session.state.lock.withLock { session.state.pin = pin }
                session.emit(.stateChanged(.connecting))
                return true
            } catch {
                session.state.lock.withLock { session.state.reason = .protocolError("Could not save the VNC certificate fingerprint: \(error.localizedDescription)") }
                return false
            }
        }
        return cb
    }
}

private extension VNCSession {
    enum Command {
        case humanKey(KeyInput), human(AgentInputEvent), releaseHuman
        case agent(UInt64, AgentInputEvent?, Receipt)
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var started = false, ended = false, stopping = false, connected = false, resizeSupported = false
        var handle: OpaquePointer?
        var reason: DisconnectReason?
        var commands: [Command] = []
        var receipts: [Receipt] = []
        var clipboard: String?, resize: DesktopSize?, refresh = false
        var clipboardRevision: UInt64 = 0
        var nextAgent: UInt64 = 0, agent: UInt64?
        var agentCancelled = false, agentPending = false
        var cancelChallenge: (@Sendable () -> Void)?
        var watchdog: Task<Void, Never>?
        var networkDeadline: ContinuousClock.Instant?
        var pin: Data?, pinURL: URL?, security: String?
    }
    final class Receipt: Sendable {
        let lock = NSLock()
        nonisolated(unsafe) var result: Result<Void, AgentInputFailure>?
        func resolve(_ failure: AgentInputFailure?) {
            lock.withLock { if result == nil { result = failure.map(Result.failure) ?? .success(()) } }
        }
        func wait(until deadline: ContinuousClock.Instant) async throws {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if let result = lock.withLock({ result }) { return try result.get() }
                try await Task.sleep(for: .milliseconds(2))
            }
            throw AgentInputFailure.timedOut
        }
    }
    final class Request: AgentInputRequest, Sendable {
        let session: VNCSession
        let id: UInt64
        let lock = NSLock()
        nonisolated(unsafe) var finished = false
        init(session: VNCSession, id: UInt64) { self.session = session; self.id = id }
        func cancel() { session.cancel(id) }
        func send(_ event: AgentInputEvent, deadline: ContinuousClock.Instant) async throws {
            try Task.checkCancellation()
            guard !lock.withLock({ finished }), let receipt = session.submit(event, id: id) else { throw AgentInputFailure.submissionFailed }
            do { try await receipt.wait(until: deadline) }
            catch { cancel(); throw error }
        }
        @discardableResult func finish() async -> Bool {
            guard lock.withLock({ if finished { return false }; finished = true; return true }) else { return false }
            return await Task.detached { [self] in
                guard let receipt = session.submit(nil, id: id) else { return false }
                do {
                    try await receipt.wait(until: .now.advanced(by: .seconds(2)))
                    return true
                } catch {
                    session.stop(.protocolError("VNC input release failed. The transport was closed."))
                    return false
                }
            }.value
        }
    }
    struct Transport: VNCInputTransport {
        let handle: OpaquePointer
        func key(_ key: VNCKey, down: Bool) -> Bool { rm_vnc_key(handle, key.keysym, key.code, down) }
        func pointer(_ point: RemotePoint, mask: UInt8) -> Bool { rm_vnc_pointer(handle, point.x, point.y, mask) }
    }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
}

private final class Wait<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var value: Value?
    private var resolved = false
    func resolve(_ answer: Value) {
        condition.lock(); defer { condition.unlock() }
        guard !resolved else { return }
        value = answer; resolved = true; condition.broadcast()
    }
    func answer() -> Value {
        condition.lock(); defer { condition.unlock() }
        while !resolved { condition.wait() }
        return value!
    }
}
private func owner(_ pointer: UnsafeMutableRawPointer?) -> VNCSession { Unmanaged<VNCSession>.fromOpaque(pointer!).takeUnretainedValue() }
private func fingerprint(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined(separator: ":") }
