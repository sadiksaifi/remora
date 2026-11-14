import CFreeRDPBridge
import CVNCBridge
import Darwin
import Foundation
import Testing

private enum FailedTransport: CaseIterable { case rdp, vnc }

@Test(arguments: FailedTransport.allCases)
private func failedTransportRetainsNumericEndpoint(transport: FailedTransport) throws {
    // Bind without listening so the connection fails. RDP uses a
    // hostname to catch retaining it instead of the resolved socket address.
    let reserved = socket(AF_INET, SOCK_STREAM, 0)
    try #require(reserved >= 0)
    defer { close(reserved) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(reserved, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(reserved, $0, &length) }
    }
    try #require(named == 0)
    let port = UInt16(bigEndian: address.sin_port)
    let numeric: String
    switch transport {
    case .vnc:
        let created = "127.0.0.1".withCString { rm_vnc_create($0, port, false, RMVNCCallbacks(), nil) }
        let session = try #require(created)
        defer { rm_vnc_free(session) }
        #expect(!rm_vnc_connect(session))
        numeric = String(cString: rm_vnc_failure_address(session))
    case .rdp:
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        numeric = try directory.path.withCString { path in
            try "localhost".withCString { host in
                try "fixture".withCString { credential in
                    var configuration = RMRDPConfiguration(
                        host: host, port: port, username: credential, domain: nil, password: credential, config_path: path,
                        width: 200, height: 200, scale_factor: 1, keyboard_layout: 0x409, iso_keyboard: false, dynamic_resolution: false)
                    var callbacks = RMRDPCallbacks()
                    let session = try #require(rm_rdp_create(&configuration, &callbacks, nil))
                    defer { rm_rdp_free(session) }
                    rm_rdp_run(session)
                    #expect(rm_rdp_failure_port(session) == port)
                    return String(cString: rm_rdp_failure_address(session))
                }
            }
        }
    }
    #expect(["127.0.0.1", "::1"].contains(numeric))
}
