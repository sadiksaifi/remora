import Darwin
import RemoraCore
import Testing
import os

@Test func connectionDiagnosisRequiresExplicitLocalNetworkDenial() {
    let denied = ConnectionFailureDiagnosis { _, _, _ in .localNetworkDenied }
    let unknown = ConnectionFailureDiagnosis { _, _, _ in .unconfirmed }
    #expect(denied.diagnose(.connectionTimedOut, host: "example.local", port: 5900) == .localNetworkDenied)
    #expect(unknown.diagnose(.connectionTimedOut, host: "example.local", port: 5900) == .connectionTimedOut)
}

@Test func connectionDiagnosisPreservesNonTransportFailures() {
    let diagnosis = ConnectionFailureDiagnosis { _, _, _ in
        Issue.record("A non-transport failure must not open a diagnostic connection.")
        return .localNetworkDenied
    }
    for reason: DisconnectReason? in [
        nil, .authenticationFailed, .certificateRejected, .connectionRefused, .hostNotFound, .protocolError("RFB"), .cancelledByUser,
    ] {
        #expect(diagnosis.diagnose(reason, host: "example.local", port: 5900) == reason)
    }
}

@Test func connectionDiagnosisCancellationWinsOverDenial() {
    let diagnosis = ConnectionFailureDiagnosis { _, _, _ in
        Issue.record("A cancelled attempt must not open a diagnostic connection.")
        return .localNetworkDenied
    }
    #expect(diagnosis.diagnose(.connectionTimedOut, host: "example.local", port: 5900, isCancelled: { true }) == .cancelledByUser)
}

@Test func connectionDiagnosisCancellationDuringInspectionWins() {
    let cancelled = OSAllocatedUnfairLock(initialState: false)
    let diagnosis = ConnectionFailureDiagnosis { host, port, _ in
        #expect(host == "example.local")
        #expect(port == 5900)
        cancelled.withLock { $0 = true }
        return .localNetworkDenied
    }
    #expect(diagnosis.diagnose(.connectionTimedOut, host: "example.local", port: 5900, isCancelled: { cancelled.withLock { $0 } }) == .cancelledByUser)
}

@Test func connectionDiagnosisClosesItsProbeWithoutProtocolData() throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    #expect(listener >= 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0 && listen(listener, 1) == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    try #require(named == 0)
    let port = UInt16(bigEndian: address.sin_port)
    // A successful diagnostic handshake cannot rewrite the original transport failure.
    #expect(ConnectionFailureDiagnosis.system.diagnose(.connectionTimedOut, host: "127.0.0.1", port: port) == .connectionTimedOut)
    var pending = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    try #require(poll(&pending, 1, 2000) == 1)
    let client = accept(listener, nil, nil)
    try #require(client >= 0)
    defer { close(client) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var byte: UInt8 = 0
    #expect(recv(client, &byte, 1, 0) == 0)
}
