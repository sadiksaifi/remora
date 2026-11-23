import Darwin
import Foundation
import RemoraCore
import Testing

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
/// `greeting`, and holds the connection open until the client closes it. The thread owns the socket.
private struct GreetingServer {
    let port: Int

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
        Thread {
            defer { close(listener) }
            // A bound port without a listener refuses connections while the socket stays open.
            guard listening else { return Thread.sleep(forTimeInterval: 3) }
            var wait = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&wait, 1, 5000) > 0 else { return }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            if let greeting { _ = greeting.withCString { write(connection, $0, strlen($0)) } }
            var byte: UInt8 = 0
            _ = read(connection, &byte, 1)
            close(connection)
        }.start()
    }
}

@Test func theProbeReadsAMacsGreeting() async throws {
    let server = try GreetingServer(greeting: "RFB 003.889\n")
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: server.port) == .apple)
}

@Test func theProbeReadsAnotherServersGreeting() async throws {
    let server = try GreetingServer(greeting: "RFB 003.008\n")
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: server.port) == .standard)
}

@Test func theProbeGivesUpOnASilentServer() async throws {
    let server = try GreetingServer(greeting: nil)
    let started = ContinuousClock.now
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: server.port, timeout: .milliseconds(300)) == nil)
    #expect(ContinuousClock.now - started < .seconds(2))
}

@Test func theProbeGivesUpOnARefusedConnection() async throws {
    let port = try GreetingServer(greeting: nil, listening: false).port
    #expect(await VNCServerProbe.mode(host: "127.0.0.1", port: port) == nil)
}
