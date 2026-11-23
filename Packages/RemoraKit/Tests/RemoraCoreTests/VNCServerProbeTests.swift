import Darwin
import Foundation
import RemoraCore
import Testing
import os

@Test func onlyAppleScreenSharingsGreetingSuggestsAppleMode() {
    #expect(VNCServerProbe.mode(forGreeting: Data("RFB 003.889\n".utf8)) == .apple)
    for version in ["003.003", "003.007", "003.008", "004.001"] {
        #expect(VNCServerProbe.mode(forGreeting: Data("RFB \(version)\n".utf8)) == .standard)
    }
    for junk in ["", "RFB 003.889", "RFB 003.889\r", "RFB 0x3.889\n", "SSH-2.0-Open\n", "HTTP/1.1 400 "] {
        #expect(VNCServerProbe.mode(forGreeting: Data(junk.utf8)) == nil)
    }
}

/// A loopback socket bound to a free port. A listening one accepts one connection, sends
/// `greeting`, and records what the client sends until the client closes. The thread owns the socket.
private final class GreetingServer: Sendable {
    let port: Int
    /// The client's bytes, set once the client has closed the connection.
    private let received = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)
    private let closed = DispatchSemaphore(value: 0)
    private let accepted = DispatchSemaphore(value: 0)

    init(greeting: String?, listening: Bool = true) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ready = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, length) == 0 && (!listening || listen(listener, 1) == 0)
                    && getsockname(listener, $0, &length) == 0
            }
        }
        guard ready else {
            close(listener)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread { [received, closed, accepted] in
            defer { close(listener) }
            // A bound port without a listener refuses connections while the socket stays open.
            guard listening else { return Thread.sleep(forTimeInterval: 3) }
            var wait = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&wait, 1, 5000) > 0 else { return }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { close(connection) }
            accepted.signal()
            if let greeting { _ = greeting.withCString { write(connection, $0, strlen($0)) } }
            var bytes: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64)
            var client = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
            while poll(&client, 1, 5000) > 0 {
                let count = read(connection, &buffer, buffer.count)
                if count <= 0 {
                    let sent = bytes
                    received.withLock { $0 = sent }
                    closed.signal()
                    return
                }
                bytes += buffer[..<count]
            }
        }.start()
    }

    /// Whether a client connected within five seconds.
    func waitForClient() -> Bool {
        accepted.wait(timeout: .now() + 5) == .success
    }

    /// What the client sent before it closed the connection, or nil if it never closed it.
    func clientBytes() -> [UInt8]? {
        guard closed.wait(timeout: .now() + 5) == .success else { return nil }
        return received.withLock { $0 }
    }
}

@Test func theProbeReadsAMacsGreetingWithoutSendingAnything() async throws {
    let server = try GreetingServer(greeting: "RFB 003.889\n")
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: server.port) == .apple)
    #expect(server.clientBytes() == [])
}

@Test func theProbeReadsAnotherServersGreetingWithoutSendingAnything() async throws {
    let server = try GreetingServer(greeting: "RFB 003.008\n")
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: server.port) == .standard)
    #expect(server.clientBytes() == [])
}

@Test func theProbeWaitsForASilentServerThenCloses() async throws {
    let server = try GreetingServer(greeting: nil)
    let started = ContinuousClock.now
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: server.port, timeout: .milliseconds(300)) == nil)
    let elapsed = ContinuousClock.now - started
    #expect(elapsed >= .milliseconds(300) && elapsed < .seconds(2))
    #expect(server.clientBytes() == [])
}

@Test func aCancelledProbeReturnsNothing() async throws {
    let server = try GreetingServer(greeting: nil)
    let probe = Task { await VNCServerProbe.mode(host: "127.0.0.1", port: server.port, timeout: .seconds(10)) }
    // Cancel only once the probe is connected and waiting for the greeting.
    try #require(await Task.detached { server.waitForClient() }.value)
    probe.cancel()
    let started = ContinuousClock.now
    #expect(await probe.value == nil)
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(server.clientBytes() == [])
}

@Test func theProbeGivesUpOnARefusedConnection() async throws {
    let port = try GreetingServer(greeting: nil, listening: false).port
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: port) == nil)
}
