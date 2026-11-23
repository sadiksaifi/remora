import Foundation
import Network
import os

/// Tells whether a VNC server is a Mac from the greeting it sends before any login.
/// The answer only suggests a mode for a new connection. A session never trusts it, because
/// anyone on the path can forge the greeting.
public enum VNCServerProbe {
    /// The suggested mode for a server's 12-byte protocol greeting, or nil when the bytes are
    /// not a VNC greeting. Only Apple Screen Sharing sends version 003.889.
    public static func mode(forGreeting greeting: Data) -> VNCMode? {
        let bytes = [UInt8](greeting)
        let digits = [4, 5, 6, 8, 9, 10]
        guard bytes.count == 12, bytes.starts(with: Array("RFB ".utf8)), bytes[7] == UInt8(ascii: "."),
            bytes[11] == UInt8(ascii: "\n"), digits.allSatisfy({ (0x30...0x39).contains(bytes[$0]) })
        else { return nil }
        return bytes == Array("RFB 003.889\n".utf8) ? .apple : .standard
    }

    /// Opens a TCP connection, reads the greeting, and closes the connection without sending
    /// anything. Returns nil when the server is unreachable, silent past `timeout`, not a VNC
    /// server, or the task is cancelled.
    public static func mode(host: String, port: Int, timeout: DispatchTimeInterval = .seconds(2)) async -> VNCMode? {
        guard let port = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)), !Task.isCancelled else {
            return nil
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "Remora VNC server probe")
        // Whichever comes first, the greeting, a failure, the timeout or cancellation, ends the wait. Cancellation
        // can come before the continuation exists, so it leaves `finished` for the continuation to see.
        let outcome = OSAllocatedUnfairLock(initialState: ProbeOutcome())
        let finish: @Sendable (Data?) -> Void = { data in
            outcome.withLock { state -> CheckedContinuation<Data?, Never>? in
                state.finished = true
                return state.waiting.take()
            }?.resume(returning: data)
        }
        defer {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        let greeting = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                let finished = outcome.withLock { state in
                    if !state.finished { state.waiting = continuation }
                    return state.finished
                }
                guard !finished else { return continuation.resume(returning: nil) }
                connection.stateUpdateHandler = { [weak connection] state in
                    switch state {
                    case .ready:
                        connection?.receive(minimumIncompleteLength: 12, maximumLength: 12) { data, _, _, _ in finish(data) }
                    // Waiting covers a Local Network prompt that the user may still accept, and a refused
                    // connection can stay in preparing while Network retries it. The timeout ends both.
                    case .failed, .cancelled: finish(nil)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        } onCancel: {
            finish(nil)
        }
        // The greeting can arrive just before the cancellation.
        guard !Task.isCancelled else { return nil }
        return greeting.flatMap(mode(forGreeting:))
    }
}

private struct ProbeOutcome {
    var finished = false
    var waiting: CheckedContinuation<Data?, Never>?
}
