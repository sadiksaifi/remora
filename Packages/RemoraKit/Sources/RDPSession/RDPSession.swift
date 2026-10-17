import CFreeRDPBridge
import Foundation
import RemoraCore
import os

private let rdpLog = Logger(subsystem: "dev.sadiksaifi.Remora", category: "RDP")

/// Owns one single-use RDP connection.
/// Invariant: stored properties are immutable except for the lock-protected StateBox.
/// The owned Thread creates, runs and frees FreeRDP. Other threads enqueue or abort.
/// Channel callbacks may arrive on FreeRDP workers; they never dispatch a Task.
public final class RDPSession: RemoteSession, @unchecked Sendable {
    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: SessionConfiguration
    private let frameSink: any FrameSink
    private let keyboardLayout: UInt32
    private let isoKeyboard: Bool
    private let state = StateBox()

    @MainActor
    public init(configuration: SessionConfiguration, frameSink: any FrameSink) {
        self.configuration = configuration
        self.frameSink = frameSink
        keyboardLayout = KeyboardLayout.current()
        isoKeyboard = KeyboardLayout.isISO()
        (events, continuation) = AsyncStream.makeStream()
    }

    public func connect() {
        state.lock.withLock {
            guard !state.started else { return }
            state.started = true
            let thread = Thread { [self] in run() }
            thread.name = "Remora RDP session"
            state.thread = thread
            continuation.yield(.stateChanged(.connecting))
            rdpLog.info("Starting session thread")
            thread.start()
        }
    }

    /// Signals cancellation and returns immediately, including during a challenge.
    public func disconnect() {
        state.lock.withLock {
            guard !state.ended else { return }
            state.cancelled = true
            state.cancelChallenge?()
            if let handle = state.handle {
                // The same lock excludes clearing/freeing the handle on the owner thread.
                rm_rdp_abort(handle)
            }
            if !state.started {
                state.started = true
                state.ended = true
                continuation.yield(.stateChanged(.disconnected(.cancelledByUser)))
                continuation.finish()
            }
        }
    }

    public var supportsDynamicResize: Bool {
        state.lock.withLock { state.connected && state.supportsDynamicResize && !state.cancelled }
    }

    public func requestResize(_ size: DesktopSize, scale: Double) {
        guard let width = UInt32(exactly: size.width), let height = UInt32(exactly: size.height) else { return }
        enqueue { rm_rdp_request_resize($0, width, height, scale) }
    }

    public func sendKey(_ key: KeyInput) {
        enqueue { rm_rdp_key($0, key.keyCode, key.isDown) }
    }

    public func sendPointer(position: RemotePoint, buttons: PointerButtons) {
        enqueue { rm_rdp_pointer($0, position.x, position.y, buttons.rawValue) }
    }

    public func sendWheel(_ wheel: WheelInput) {
        enqueue { rm_rdp_wheel($0, wheel.vertical, wheel.horizontal) }
    }

    public func synchronize(locks: LockKeys) {
        state.lock.withLock {
            state.locks = locks
            if state.connected, !state.cancelled, let handle = state.handle {
                rm_rdp_synchronize(handle, locks.rawValue)
            }
        }
    }

    public func releaseAll() {
        enqueue { rm_rdp_release_all($0) }
    }

    private func enqueue(_ command: (OpaquePointer) -> Void) {
        state.lock.withLock {
            guard state.connected, !state.cancelled, let handle = state.handle else { return }
            // Excludes handle teardown for the entire C enqueue operation.
            command(handle)
        }
    }

    private func run() {
        autoreleasepool {
            guard !state.lock.withLock({ state.cancelled }) else {
                finish(.cancelledByUser)
                return
            }
            do {
                let path = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Remora/FreeRDP")
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                guard let handle = createHandle(configPath: path.path) else {
                    finish(.protocolError("Invalid session configuration or FreeRDP allocation failed."))
                    return
                }
                state.lock.withLock {
                    state.handle = handle
                    if state.cancelled { rm_rdp_abort(handle) }
                }
                rm_rdp_run(handle)
                state.lock.withLock { state.connected = false; state.handle = nil }
                // run has stopped all channel workers. No callback can use the Unmanaged
                // pointer after free. The Thread's strong capture keeps self alive here.
                rm_rdp_free(handle)
                finish(state.lock.withLock { state.reason })
            } catch {
                finish(.protocolError(error.localizedDescription))
            }
        }
    }

    private func createHandle(configPath: String) -> OpaquePointer? {
        let size = configuration.desktopSize
        guard let width = UInt32(exactly: size.width), let height = UInt32(exactly: size.height) else {
            return nil
        }
        let strings = [configuration.host, configuration.username, configuration.domain,
                       configuration.password, configPath].map { $0.flatMap { strdup($0) } }
        defer { strings.forEach { free($0) } }
        guard strings[0] != nil, strings[1] != nil, strings[2] != nil, strings[4] != nil,
              configuration.password == nil || strings[3] != nil else { return nil }
        var config = RMRDPConfiguration(
            host: UnsafePointer(strings[0]), port: configuration.port,
            username: UnsafePointer(strings[1]), domain: UnsafePointer(strings[2]),
            password: UnsafePointer(strings[3]), config_path: UnsafePointer(strings[4]),
            width: width, height: height, scale_factor: configuration.scaleFactor,
            keyboard_layout: keyboardLayout, iso_keyboard: isoKeyboard
        )
        var callbacks = RMRDPCallbacks()
        callbacks.connected = { user in
            let owner = session(user)
            owner.state.lock.withLock {
                owner.state.connected = true
                if let handle = owner.state.handle {
                    rm_rdp_synchronize(handle, owner.state.locks.rawValue)
                }
            }
            owner.emit(.stateChanged(.connected))
        }
        callbacks.disconnected = { user, reason, message in
            let owner = session(user)
            let mapped = disconnectReason(reason, message: string(message))
            owner.state.lock.withLock { owner.state.reason = mapped }
        }
        callbacks.desktop_size = { user, width, height, requested in
            session(user).emit(.desktopSizeChanged(DesktopSize(width: Int(width), height: Int(height)), requested: requested))
        }
        callbacks.dynamic_resize = { user, available in
            let owner = session(user)
            owner.state.lock.withLock { owner.state.supportsDynamicResize = available }
            owner.emit(.dynamicResizeChanged(available))
        }
        callbacks.frame = { user, pixels, width, height, stride, rectangles, count in
            guard let pixels else { return }
            let dirty = UnsafeBufferPointer(start: rectangles, count: count).map {
                DirtyRectangle(x: Int($0.x), y: Int($0.y), width: Int($0.width), height: Int($0.height))
            }
            session(user).frameSink.consume(BorrowedFrame(
                pixels: UnsafeRawPointer(pixels), width: Int(width), height: Int(height),
                stride: Int(stride), dirtyRectangles: dirty
            ))
        }
        callbacks.cursor = { user, kind, pixels, width, height, hotspotX, hotspotY in
            let cursor: RemoteCursor
            switch kind {
            case RMRDP_CURSOR_IMAGE:
                guard let pixels, width > 0, height > 0,
                      let x = UInt16(exactly: hotspotX), let y = UInt16(exactly: hotspotY) else { return }
                cursor = .image(pixels: Data(bytes: pixels, count: Int(width) * Int(height) * 4),
                                width: Int(width), height: Int(height), hotspot: RemotePoint(x: x, y: y))
            case RMRDP_CURSOR_HIDDEN: cursor = .hidden
            default: cursor = .systemDefault
            }
            session(user).emit(.cursorChanged(cursor))
        }
        callbacks.credentials = { user, username, domain, rejected, newUsername, newDomain, newPassword in
            let owner = session(user)
            let answer: SessionCredentials? = owner.challenge(cancel: nil) { responder in
                [.stateChanged(.awaitingCredentials), .credentialsChallenge(CredentialsChallenge(
                    username: string(username), domain: string(domain),
                    reason: rejected ? .rejected : .missing, responder: responder
                ))]
            }
            guard let answer else { return false }
            let u = strdup(answer.username)
            let d = strdup(answer.domain)
            let p = strdup(answer.password)
            guard u != nil, d != nil, p != nil else {
                free(u)
                free(d)
                free(p)
                return false
            }
            newUsername?.pointee = u
            newDomain?.pointee = d
            newPassword?.pointee = p
            owner.emit(.stateChanged(.connecting))
            return true
        }
        callbacks.trust = { user, host, port, subject, issuer, fingerprint, oldFingerprint in
            let owner = session(user)
            let decision: CertificateDecision = owner.challenge(cancel: .reject) { responder in
                [.stateChanged(.awaitingTrust), .trustChallenge(TrustChallenge(
                    host: string(host), port: port, subject: string(subject), issuer: string(issuer),
                    fingerprint: string(fingerprint),
                    status: oldFingerprint.map { .changed(oldFingerprint: string($0)) } ?? .new,
                    responder: responder
                ))]
            }
            if decision == .trust { owner.emit(.stateChanged(.connecting)) }
            return decision == .trust
        }
        return rm_rdp_create(&config, &callbacks, Unmanaged.passUnretained(self).toOpaque())
    }

    private func emit(_ event: SessionEvent) {
        state.lock.withLock {
            guard !state.ended, !state.cancelled else { return }
            continuation.yield(event)
        }
    }

    private func finish(_ reason: DisconnectReason?) {
        state.lock.withLock {
            guard !state.ended else { return }
            rdpLog.info("Session thread ended: \(self.state.cancelled ? "Cancelled" : reason?.description ?? "Session ended", privacy: .public)")
            state.ended = true
            state.thread = nil
            state.cancelChallenge = nil
            continuation.yield(.stateChanged(.disconnected(state.cancelled ? .cancelledByUser : reason)))
            continuation.finish()
        }
    }

    private func challenge<Answer: Sendable>(
        cancel: Answer,
        events makeEvents: (SessionResponder<Answer>) -> [SessionEvent]
    ) -> Answer {
        let wait = ChallengeWait<Answer>()
        let responder = SessionResponder<Answer> { wait.resolve($0) }
        state.lock.withLock {
            if state.cancelled {
                responder.respond(cancel)
            } else {
                state.cancelChallenge = { responder.respond(cancel) }
                for event in makeEvents(responder) { continuation.yield(event) }
            }
        }
        let answer = wait.answer()
        state.lock.withLock { state.cancelChallenge = nil }
        return answer
    }
}

private final class StateBox: @unchecked Sendable {
    let lock = NSLock()
    // Every access, including abort and removing the handle before free, holds lock.
    var connected = false
    var supportsDynamicResize = false
    var locks: LockKeys = []
    var started = false
    var ended = false
    var cancelled = false
    var thread: Thread?
    var handle: OpaquePointer?
    var reason: DisconnectReason?
    var cancelChallenge: (@Sendable () -> Void)?
}

private final class ChallengeWait<Answer: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Answer?
    private var resolved = false

    func resolve(_ answer: Answer) {
        condition.lock()
        defer { condition.unlock() }
        guard !resolved else { return }
        result = answer
        resolved = true
        condition.broadcast()
    }

    func answer() -> Answer {
        condition.lock()
        defer { condition.unlock() }
        while !resolved { condition.wait() }
        return result!
    }
}

private func session(_ user: UnsafeMutableRawPointer?) -> RDPSession {
    Unmanaged<RDPSession>.fromOpaque(user!).takeUnretainedValue()
}

private func string(_ value: UnsafePointer<CChar>?) -> String {
    value.map { String(cString: $0) } ?? ""
}

private func disconnectReason(_ reason: RMRDPDisconnectReason, message: String) -> DisconnectReason? {
    switch reason {
    case RMRDP_DISCONNECT_NONE: nil
    case RMRDP_DISCONNECT_AUTHENTICATION_FAILED: .authenticationFailed
    case RMRDP_DISCONNECT_CERTIFICATE_REJECTED: .certificateRejected
    case RMRDP_DISCONNECT_HOST_NOT_FOUND: .hostNotFound
    case RMRDP_DISCONNECT_CONNECTION_REFUSED: .connectionRefused
    case RMRDP_DISCONNECT_CONNECTION_TIMED_OUT: .connectionTimedOut
    case RMRDP_DISCONNECT_SERVER_ENDED_SESSION: .serverEndedSession(message)
    case RMRDP_DISCONNECT_CANCELLED: .cancelledByUser
    default: .protocolError(message)
    }
}
