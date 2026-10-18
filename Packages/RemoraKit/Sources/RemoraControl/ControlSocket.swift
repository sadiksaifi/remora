import Foundation
import Network
import Darwin

public struct ControlEndpoint: Sendable {
    public let path: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        path = environment["REMORA_SOCKET"] ?? "/tmp/remora-\(getuid())/control.sock"
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104 else {
            throw ControlFailure(.invalidArgument, "The control socket needs an absolute path shorter than 104 UTF-8 bytes.")
        }
    }
}

/// One request per connection. Callers may retry readiness probes, never a submitted mutation.
public struct ControlClient: Sendable {
    public let endpoint: ControlEndpoint
    public init(endpoint: ControlEndpoint) { self.endpoint = endpoint }

    public func request(_ request: ControlRequest, timeout: Double, isMutation: Bool = true) async throws -> ControlResponse {
        let connection = NWConnection(to: .unix(path: endpoint.path), using: .tcp)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var submitted = false
        defer { connection.cancel() }
        do {
            try await connect(connection, timeout: timeout)
            let data = try JSONEncoder().encode(request) + Data([10])
            guard data.count <= maximumLineSize else {
                throw ControlFailure(.invalidArgument, "The request exceeds 1 MiB.")
            }
            submitted = true
            try await send(data, on: connection, timeout: remaining(deadline))
            let line = try await readLine(on: connection, timeout: remaining(deadline))
            return try JSONDecoder().decode(ControlResponse.self, from: line)
        } catch let error as ControlFailure where error.code == .timeout || error.code == .cancelled || error.code == .invalidArgument {
            throw error
        } catch {
            let unknownOutcome = submitted && isMutation
            throw ControlFailure(submitted ? (unknownOutcome ? .outcomeUnknown : .ioFailed) : .appUnavailable,
                submitted ? (unknownOutcome ? "The app reply was lost. The command may have completed." : "The app reply was lost.") : "The app control socket is unavailable.",
                hint: "Inspect app status before retrying a command that changes state.")
        }
    }
}

/// An app operation can arrange cleanup only after its reply has reached the socket.
public struct ControlReply: Sendable {
    public let response: ControlResponse
    public let afterSend: (@Sendable () async -> Void)?

    public init(_ response: ControlResponse, afterSend: (@Sendable () async -> Void)? = nil) {
        self.response = response
        self.afterSend = afterSend
    }
}

public actor ControlServer {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlReply
    private let endpoint: ControlEndpoint
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    public init(endpoint: ControlEndpoint, handler: @escaping Handler) {
        self.endpoint = endpoint
        self.handler = handler
    }

    public func start() async throws {
        guard listener == nil else { return }
        let directory = URL(fileURLWithPath: endpoint.path).deletingLastPathComponent()
        if endpoint.path == "/tmp/remora-\(getuid())/control.sock" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        if FileManager.default.fileExists(atPath: endpoint.path) {
            let probe = NWConnection(to: .unix(path: endpoint.path), using: .tcp)
            defer { probe.cancel() }
            do {
                try await connect(probe, timeout: 1)
            } catch let error as NWError where error == .posix(.ECONNREFUSED) || error == .posix(.ENOENT) {
                try FileManager.default.removeItem(atPath: endpoint.path)
            }
            if FileManager.default.fileExists(atPath: endpoint.path) {
                throw ControlFailure(.ioFailed, "A control listener already uses \(endpoint.path).")
            }
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: endpoint.path)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer { listener.stateUpdateHandler = nil }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        do {
            try await NetworkOperation<Void>.run(timeout: 10, cancel: { listener.cancel() }) { finish in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case .failed(let error): finish(.failure(error))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: socketQueue)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpoint.path)
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    public func stop() {
        guard let listener else { return }
        self.listener = nil
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        try? FileManager.default.removeItem(atPath: endpoint.path)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: socketQueue)
        Task {
            defer {
                connection.cancel()
                connections[id] = nil
            }
            let reply: ControlReply
            do {
                let line = try await readLine(on: connection, timeout: 10)
                let request: ControlRequest
                do { request = try JSONDecoder().decode(ControlRequest.self, from: line) }
                catch { throw ControlFailure(.invalidArgument, "Invalid control request JSON or fields.") }
                reply = await handler(request)
            } catch {
                reply = ControlReply(.failure(error as? ControlFailure ?? ControlFailure(.ioFailed, error.localizedDescription)))
            }
            do {
                let data = try JSONEncoder().encode(reply.response) + Data([10])
                try await send(data, on: connection, timeout: 10)
            } catch { /* The operation remains committed even if its reply is lost. */ }
            await reply.afterSend?()
        }
    }
}

private let socketQueue = DispatchQueue(label: "dev.sadiksaifi.Remora.control", qos: .userInitiated)
private let maximumLineSize = 1_048_576

private func remaining(_ deadline: ContinuousClock.Instant) -> Double {
    let parts = ContinuousClock.now.duration(to: deadline).components
    return max(0, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
}

private func connect(_ connection: NWConnection, timeout: Double) async throws {
    defer { connection.stateUpdateHandler = nil }
    try await NetworkOperation<Void>.run(timeout: timeout, cancel: { connection.cancel() }) { finish in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(.success(()))
            case .waiting(let error), .failed(let error): finish(.failure(error))
            case .cancelled: finish(.failure(CancellationError()))
            default: break
            }
        }
        connection.start(queue: socketQueue)
    }
}

private func send(_ data: Data, on connection: NWConnection, timeout: Double) async throws {
    try await NetworkOperation<Void>.run(timeout: timeout, cancel: { connection.cancel() }) { finish in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { finish(.failure(error)) } else { finish(.success(())) }
        })
    }
}

private func readLine(on connection: NWConnection, timeout: Double) async throws -> Data {
    try await NetworkOperation<Data>.run(timeout: timeout, cancel: { connection.cancel() }) { finish in
        receiveLine(on: connection, buffer: Data(), finish: finish)
    }
}

private func receiveLine(on connection: NWConnection, buffer: Data,
                         finish: @escaping @Sendable (Result<Data, any Error>) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, maximumLineSize + 1 - buffer.count)) { data, _, complete, error in
        var buffer = buffer
        if let data { buffer.append(data) }
        if let newline = buffer.firstIndex(of: 10), newline < maximumLineSize {
            finish(.success(Data(buffer[..<newline])))
        } else if buffer.count >= maximumLineSize {
            finish(.failure(ControlFailure(.invalidArgument, "The JSON line exceeds 1 MiB.")))
        } else if let error { finish(.failure(error)) }
        else if complete { finish(.failure(ControlFailure(.ioFailed, "The socket closed before a complete JSON line."))) }
        else { receiveLine(on: connection, buffer: buffer, finish: finish) }
    }
}

/// Network callbacks, deadline and task cancellation race to resume a continuation exactly once.
private final class NetworkOperation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?
    private var timer: DispatchWorkItem?
    private let cancel: @Sendable () -> Void

    private init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

    static func run(timeout: Double, cancel: @escaping @Sendable () -> Void,
                    start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
        let operation = NetworkOperation(cancel: cancel)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.lock.lock()
                if let result = operation.result {
                    operation.lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                operation.continuation = continuation
                let timer = DispatchWorkItem { [weak operation] in operation?.abort(ControlFailure(.timeout, "The command timed out.", hint: "Inspect current state before retrying.")) }
                operation.timer = timer
                operation.lock.unlock()
                guard timeout > 0 else {
                    operation.abort(ControlFailure(.timeout, "The command timed out."))
                    return
                }
                socketQueue.asyncAfter(deadline: .now() + timeout, execute: timer)
                start { operation.finish($0) }
            }
        } onCancel: {
            operation.abort(ControlFailure(.cancelled, "The command was interrupted."))
        }
    }

    private func abort(_ error: any Error) {
        if finish(.failure(error)) { cancel() }
    }

    @discardableResult private func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        timer?.cancel()
        timer = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}
