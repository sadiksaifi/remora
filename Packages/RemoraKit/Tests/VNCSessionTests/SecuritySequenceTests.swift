import Foundation
import RemoraCore
import Testing
import VNCSession

private struct SecuritySequenceFrames: FrameSink { func consume(_ frame: BorrowedFrame) {} }

/// Independent loopback RFB/TLS peer. Xcode's Python and macOS OpenSSL generate
/// a disposable self-signed identity; no network target or saved credentials are used.
private let securitySequencePeer = #"""
    import pathlib, socket, ssl, struct, subprocess, sys
    root = pathlib.Path(sys.argv[1])
    config = root / 'certificate.conf'
    config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3\n'
                      '[dn]\nCN=localhost\n[v3]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
    subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                    '-sha256', '-days', '1', '-config', str(config), '-keyout', str(root/'key.pem'),
                    '-out', str(root/'cert.pem')], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=5)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(str(root/'cert.pem'), str(root/'key.pem'))
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(5)
    print(listener.getsockname()[1], flush=True)

    def exact(c, count):
        data = b''
        while len(data) < count:
            part = c.recv(count - len(data))
            if not part: raise EOFError('incomplete handshake')
            data += part
        return data

    for index, mode in enumerate(['classic', 'tls', 'classic', 'tls', 'tls-reject']):
        c, _ = listener.accept()
        c.settimeout(3)
        try:
            c.sendall(b'RFB 003.008\n')
            assert exact(c, 12) == b'RFB 003.008\n'
            scheme = 2 if mode == 'classic' else 19
            offers = [2] if mode == 'classic' else [30, 33, 36, 2, 35, 19, 250]
            if index == 3: offers.reverse()
            c.sendall(bytes([len(offers)] + offers))
            assert exact(c, 1) == bytes([scheme])
            if mode == 'classic':
                c.sendall(bytes(range(16)))
                # Independently derived with system LibreSSL DES-ECB and the
                # bit-reversed first eight password bytes for 'test-only'.
                assert exact(c, 16).hex() == '705c570436bf757817820147dcdb47cf'
            else:
                c.sendall(b'\x00\x02')
                assert exact(c, 2) == b'\x00\x02'
                c.sendall(b'\x00\x01' + struct.pack('>I', 262))
                assert exact(c, 4) == struct.pack('>I', 262)
                c.sendall(b'\x01')
                c = tls.wrap_socket(c, server_side=True)
                user_len, pass_len = struct.unpack('>II', exact(c, 8))
                assert exact(c, user_len) == b'synthetic'
                assert exact(c, pass_len) == b'test-only'
            if mode == 'tls-reject':
                reason = b'synthetic TLS rejection'
                c.sendall(struct.pack('>II', 1, len(reason)) + reason)
                assert c.recv(1) == b'' # No alternate security exchange on this connection.
                listener.settimeout(0.25)
                try:
                    extra, _ = listener.accept()
                except socket.timeout:
                    pass
                else:
                    extra.close()
                    raise AssertionError('unexpected fallback connection')
                continue
            c.sendall(bytes(4)) # SecurityResult success
            exact(c, 1) # ClientInit
            c.sendall(struct.pack('>HHBBBBHHHBBBBBBI', 16, 16, 32, 24, 0, 1,
                                  255, 255, 255, 16, 8, 0, 0, 0, 0, 0))
            while c.recv(4096): pass
        finally:
            c.close()
    listener.close()
    """#

@Test @MainActor func vncClassicAuthenticationDoesNotPoisonLaterTLSSessions() async throws {
    // A completed Apple-mode SRP login must not change the default OpenSSL context
    // or the following standard classic/TLS transcripts in this process.
    try await verifyApplePrecedesStandardSecuritySequence()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    peer.arguments = ["-u", "-c", securitySequencePeer, directory.path]
    let output = Pipe()
    peer.standardOutput = output
    try peer.run()
    defer {
        if peer.isRunning {
            peer.terminate()
            peer.waitUntilExit()
        }
    }
    let portText = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
    let port = try #require(UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)))
    var connected: [String] = []
    var trustDecisions = 0
    for (index, expected) in [
        "VNC authentication (unencrypted desktop)", "VeNCrypt X509Plain", "VNC authentication (unencrypted desktop)", "VeNCrypt X509Plain",
        "TLS authentication rejection",
    ].enumerated() {
        let session = VNCSession(
            configuration: .init(host: "127.0.0.1", port: port, username: "synthetic", password: "test-only", desktopSize: .init(width: 16, height: 16)),
            frameSink: SecuritySequenceFrames(), certificateStoreURL: directory.appendingPathComponent("pins"))
        let fallback = Task {
            do {
                try await Task.sleep(for: .seconds(3))
                session.disconnect()
            } catch {}
        }
        defer {
            fallback.cancel()
            session.disconnect()
        }
        var didConnect = false
        var terminal: DisconnectReason?
        session.connect()
        for await event in session.events {
            switch event {
            case .trustChallenge(let challenge):
                trustDecisions += 1
                challenge.responder.respond(.trust)
            case .stateChanged(.disconnected(let reason)): terminal = reason
            case .stateChanged(.connected):
                didConnect = true
                connected.append(try #require(session.negotiatedSecurity))
                session.disconnect()
            default: break
            }
        }
        if index == 4 {
            #expect(!didConnect)
            #expect(terminal == .authenticationFailed)
        } else {
            #expect(didConnect, "Expected a complete \(expected) session after the preceding session closed.")
            if !didConnect { break }
        }
    }
    #expect(connected == ["VNC authentication (unencrypted desktop)", "VeNCrypt X509Plain", "VNC authentication (unencrypted desktop)", "VeNCrypt X509Plain"])
    #expect(trustDecisions == 1)  // The second TLS connection uses the isolated saved pin.
    if connected.count == 4 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while peer.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!peer.isRunning)
        if !peer.isRunning { #expect(peer.terminationStatus == 0) }
    }
}
