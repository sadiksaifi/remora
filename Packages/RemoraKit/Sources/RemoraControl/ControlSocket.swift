import Darwin
import Foundation
import Network

public struct ControlEndpoint: Sendable {
    public let path: String

    /// The socket sits in the app's own Application Support folder, which only this user can write,
    /// so the CLI reaches only the app that contains it, never the other variant or another account's socket.
    public init() throws {
        path = AppIdentity.current.supportDirectory.appending(path: "control.sock").path
        guard path.utf8.count < 104 else {
            throw ControlFailure(
                .unsupported, "The control socket path \(path) is \(path.utf8.count) bytes, and macOS allows at most 103.",
                hint: "Use \(AppIdentity.current.name) from a user account whose home folder path is shorter.")
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
            throw ControlFailure(
                submitted ? (unknownOutcome ? .outcomeUnknown : .ioFailed) : .appUnavailable,
                submitted
                    ? (unknownOutcome ? "The app reply was lost. The command may have completed." : "The app reply was lost.")
                    : "The app control socket is unavailable.")
        }
    }
    public func screenshot(_ request: ControlRequest, timeout: Double) async throws -> (ControlResponse, Data) {
        let connection = NWConnection(to: .unix(path: endpoint.path), using: .tcp)
        defer { connection.cancel() }
        do {
            try await connect(connection, timeout: timeout)
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            try await send(try JSONEncoder().encode(request) + Data([10]), on: connection, timeout: remaining(deadline))
            let reader = ControlReader(connection: connection)
            let response = try JSONDecoder().decode(ControlResponse.self, from: await reader.line(timeout: remaining(deadline)))
            if case .failure = response { return (response, Data()) }
            guard case .success(.object(let fields)) = response, case .number(let count) = fields["byteLength"],
                count > 0, count <= 256 * 1024 * 1024, count.rounded() == count
            else {
                throw ControlFailure(.ioFailed, "The screenshot reply has no valid PNG byte length.")
            }
            return (response, try await reader.bytes(Int(count), timeout: remaining(deadline)))
        } catch let failure as ControlFailure { throw failure } catch {
            throw ControlFailure(.ioFailed, "The screenshot transfer failed.")
        }
    }

    public func events(_ request: ControlRequest, timeout: Double?, receive: @Sendable (ControlEvent) throws -> Void) async throws {
        let connection = NWConnection(to: .unix(path: endpoint.path), using: .tcp)
        defer { connection.cancel() }
        do {
            try await connect(connection, timeout: 10)
            try await send(try JSONEncoder().encode(request) + Data([10]), on: connection, timeout: 10)
            let reader = ControlReader(connection: connection)
            let deadline = timeout.map { ContinuousClock.now.advanced(by: .seconds($0)) }
            while true {
                let line: Data
                do { line = try await reader.line(timeout: deadline.map(remaining)) } catch is ControlStreamEnd { return }
                if let response = try? JSONDecoder().decode(ControlResponse.self, from: line), case .failure(let failure) = response { throw failure }
                try receive(JSONDecoder().decode(ControlEvent.self, from: line))
            }
        } catch let failure as ControlFailure { throw failure } catch {
            throw ControlFailure(.ioFailed, "The event stream failed.")
        }
    }

}

/// An app operation can arrange cleanup only after its reply has reached the socket.
public struct ControlReply: Sendable {
    public let response: ControlResponse
    public let payload: Data?
    public let events: AsyncThrowingStream<ControlEvent, any Error>?
    public let afterSend: (@Sendable () async -> Void)?

    public init(
        _ response: ControlResponse, payload: Data? = nil, events: AsyncThrowingStream<ControlEvent, any Error>? = nil,
        afterSend: (@Sendable () async -> Void)? = nil
    ) {
        self.payload = payload
        self.events = events
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

    /// The socket has no token, peer check or approval prompt by design. File modes limit it to
    /// this user, and installing the CLI symlink is the only opt-in.
    public func start() async throws {
        guard listener == nil else { return }
        let directory = URL(fileURLWithPath: endpoint.path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
            do {
                let line = try await readLine(on: connection, timeout: 10)
                let request: ControlRequest
                do { request = try JSONDecoder().decode(ControlRequest.self, from: line) } catch {
                    throw ControlFailure(.invalidArgument, "Invalid control request JSON or fields.")
                }
                let operation = Task {
                    let reply = await handler(request)
                    do {
                        if let events = reply.events {
                            for try await event in events {
                                try await send(try JSONEncoder().encode(event) + Data([10]), on: connection, timeout: nil)
                            }
                        } else {
                            try await send(try JSONEncoder().encode(reply.response) + Data([10]), on: connection, timeout: 10)
                            if let payload = reply.payload { try await send(payload, on: connection, timeout: 10) }
                        }
                    } catch { await sendFailure(error, on: connection) }
                    await reply.afterSend?()
                }
                // EOF cancels the complete operation, including streaming and demand cleanup.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in operation.cancel() }
                await operation.value
            } catch { await sendFailure(error, on: connection) }
        }
    }
}

private let socketQueue = DispatchQueue(label: "com.peblon.remora.control", qos: .userInitiated)
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

private func send(_ data: Data, on connection: NWConnection, timeout: Double?) async throws {
    try await NetworkOperation<Void>.run(timeout: timeout, cancel: { connection.cancel() }) { finish in
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            })
    }
}

private func readLine(on connection: NWConnection, timeout: Double) async throws -> Data {
    try await NetworkOperation<Data>.run(timeout: timeout, cancel: { connection.cancel() }) { finish in
        receiveLine(on: connection, buffer: Data(), finish: finish)
    }
}

private func receiveLine(
    on connection: NWConnection, buffer: Data,
    finish: @escaping @Sendable (Result<Data, any Error>) -> Void
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, maximumLineSize + 1 - buffer.count)) { data, _, complete, error in
        var buffer = buffer
        if let data { buffer.append(data) }
        if let newline = buffer.firstIndex(of: 10), newline < maximumLineSize {
            finish(.success(Data(buffer[..<newline])))
        } else if buffer.count >= maximumLineSize {
            finish(.failure(ControlFailure(.invalidArgument, "The JSON line exceeds 1 MiB.")))
        } else if let error {
            finish(.failure(error))
        } else if complete {
            finish(.failure(ControlFailure(.ioFailed, "The socket closed before a complete JSON line.")))
        } else {
            receiveLine(on: connection, buffer: buffer, finish: finish)
        }
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

    static func run(
        timeout: Double?, cancel: @escaping @Sendable () -> Void,
        start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
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
                if let timeout {
                    let timer = DispatchWorkItem { [weak operation] in
                        operation?.abort(ControlFailure(.timeout, "The command timed out."))
                    }
                    operation.timer = timer
                    socketQueue.asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
                }
                operation.lock.unlock()
                if let timeout, timeout <= 0 {
                    operation.abort(ControlFailure(.timeout, "The command timed out."))
                    return
                }
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
        guard self.result == nil else {
            lock.unlock()
            return false
        }
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

/// Retains bytes received past a JSON newline, including the start of a PNG payload.
private actor ControlReader {
    let connection: NWConnection
    var buffer = Data()
    init(connection: NWConnection) { self.connection = connection }

    func line(timeout: Double?) async throws -> Data {
        let deadline = timeout.map { ContinuousClock.now.advanced(by: .seconds($0)) }
        while buffer.firstIndex(of: 10) == nil {
            guard buffer.count < maximumLineSize else { throw ControlFailure(.ioFailed, "The JSON line exceeds 1 MiB.") }
            do { try await receive(timeout: deadline.map(remaining)) } catch is ControlStreamEnd where !buffer.isEmpty {
                throw ControlFailure(.ioFailed, "The control stream closed mid-line.")
            }
        }
        let newline = buffer.firstIndex(of: 10)!
        guard newline < maximumLineSize else { throw ControlFailure(.ioFailed, "The JSON line exceeds 1 MiB.") }
        let line = Data(buffer[..<newline])
        buffer.removeSubrange(...newline)
        return line
    }

    func bytes(_ count: Int, timeout: Double) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while buffer.count < count { try await receive(timeout: remaining(deadline)) }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    private func receive(timeout: Double?) async throws {
        let connection = connection
        let data: Data = try await NetworkOperation.run(timeout: timeout, cancel: { connection.cancel() }) { finish in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let data, !data.isEmpty { finish(.success(data)) } else { finish(.failure(error ?? ControlStreamEnd())) }
            }
        }
        buffer.append(data)
    }
}

private struct ControlStreamEnd: Error {}

private func sendFailure(_ error: any Error, on connection: NWConnection) async {
    let failure = error as? ControlFailure ?? ControlFailure(.ioFailed, error.localizedDescription)
    if !Task.isCancelled, let data = try? JSONEncoder().encode(ControlResponse.failure(failure)) {
        try? await send(data + Data([10]), on: connection, timeout: 1)
    }
}
