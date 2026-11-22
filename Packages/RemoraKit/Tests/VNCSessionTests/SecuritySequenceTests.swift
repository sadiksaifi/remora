import Foundation
import RemoraCore
import Testing
import VNCSession
import os

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

/// VeNCrypt X509Plain peer that stops reading at the start of a clipboard upload, then drains to the client's close.
private let tlsStallPeer = #"""
    import json, pathlib, socket, ssl, struct, subprocess, sys, time
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
    # A fixed receive buffer turns off autotuning, which could otherwise absorb the whole upload.
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 65536)
    listener.listen(1)
    listener.settimeout(10)
    print(listener.getsockname()[1], flush=True)
    report = {}

    def exact(c, count):
        data = b''
        while len(data) < count:
            part = c.recv(count - len(data))
            if not part: raise EOFError('incomplete message')
            data += part
        return data

    c, _ = listener.accept()
    c.settimeout(10)
    try:
        c.sendall(b'RFB 003.008\n')
        assert exact(c, 12) == b'RFB 003.008\n'
        c.sendall(bytes([1, 19]))
        assert exact(c, 1) == bytes([19])
        c.sendall(b'\x00\x02')
        assert exact(c, 2) == b'\x00\x02'
        c.sendall(b'\x00\x01' + struct.pack('>I', 262))
        assert exact(c, 4) == struct.pack('>I', 262)
        c.sendall(b'\x01')
        c = tls.wrap_socket(c, server_side=True)
        user_len, pass_len = struct.unpack('>II', exact(c, 8))
        exact(c, user_len + pass_len)
        c.sendall(bytes(4))
        exact(c, 1)
        c.sendall(struct.pack('>HHBBBBHHHBBBBBBI', 16, 16, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0, 0, 0, 0))
        sent_frame = False
        while True:
            kind = exact(c, 1)[0]
            if kind == 0: exact(c, 19)
            elif kind == 2:
                head = exact(c, 3)
                exact(c, int.from_bytes(head[1:], 'big') * 4)
            elif kind == 3:
                exact(c, 9)
                if not sent_frame:
                    c.sendall(struct.pack('>BBHHHHHi', 0, 0, 1, 0, 0, 16, 16, 0) + bytes(16 * 16 * 4))
                    sent_frame = True
            elif kind == 6:
                report['stalled_upload_declared'] = int.from_bytes(exact(c, 7)[3:], 'big')
                break
            else: raise ValueError('unexpected message %d' % kind)
        time.sleep(19)
        drained = 0
        try:
            while part := c.recv(65536): drained += len(part)
        except (ssl.SSLError, ConnectionError):
            pass  # The client closed without a TLS close_notify, which ends a ragged stream.
        report['stalled_bytes'] = drained
        report['closed_after_stall'] = True
    except Exception as error:
        report['error'] = repr(error)
    finally:
        c.close()
        listener.close()
    print(json.dumps(report), flush=True)
    """#

// The peer stops reading at the start of a 640 KiB upload inside TLS, which fills the socket buffers. SSL_write
// then reports WANT_WRITE until the deadline: 10 s plus the message at 1 Mbit/s, about 15 s.
@Test @MainActor func aTLSPeerThatStopsReadingEndsTheSessionAtTheWriteDeadline() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = Process()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    peer.arguments = ["-u", "-c", tlsStallPeer, directory.path]
    let output = Pipe()
    peer.standardOutput = output
    try peer.run()
    defer {
        if peer.isRunning {
            peer.terminate()
            peer.waitUntilExit()
        }
    }
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
    let port = try #require(UInt16(String(decoding: line, as: UTF8.self)))
    let text = String(String.UnicodeScalarView((0..<640 * 1024).map { _ in Unicode.Scalar(UInt8.random(in: 0x20...0x7e)) }))
    let frames = StallFrames()
    let session = VNCSession(
        configuration: .init(host: "127.0.0.1", port: port, username: "synthetic", password: "test-only", desktopSize: .init(width: 16, height: 16)),
        frameSink: frames, certificateStoreURL: directory.appendingPathComponent("pins"))
    let fallback = Task {
        try? await Task.sleep(for: .seconds(25))
        session.disconnect()
    }
    defer {
        fallback.cancel()
        session.disconnect()
    }
    let started = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    var elapsed: Duration?
    var terminals: [DisconnectReason] = []
    let upload = Task { @MainActor in
        let firstFrame = ContinuousClock.now.advanced(by: .seconds(10))
        while frames.count == 0, ContinuousClock.now < firstFrame { try await Task.sleep(for: .milliseconds(10)) }
        guard frames.count > 0 else { return }
        started.withLock { $0 = .now }
        session.setLocalClipboard(text: text)
    }
    defer { upload.cancel() }
    session.connect()
    for await event in session.events {
        switch event {
        case .trustChallenge(let challenge): challenge.responder.respond(.trust)
        case .stateChanged(.disconnected(let reason)):
            elapsed = started.withLock { $0 }?.duration(to: .now)
            if let reason { terminals.append(reason) }
        default: break
        }
    }
    let report = await Task.detached {
        peer.waitUntilExit()
        return output.fileHandleForReading.readDataToEndOfFile()
    }.value
    let wire = try #require(JSONSerialization.jsonObject(with: report) as? [String: Any])
    #expect(wire["error"] == nil, "\(wire["error"] ?? "")")
    #expect(terminals == [.connectionTimedOut])
    let declared = try #require(wire["stalled_upload_declared"] as? Int)
    let deadline = 10 + Double(declared + 8) / 131_072
    let duration = try #require(elapsed, "The upload never started.")
    #expect(duration >= .seconds(deadline - 0.25) && duration < .seconds(deadline + 3), "\(duration), deadline \(deadline) s")
    // The client closed its transport partway through the upload.
    #expect(wire["closed_after_stall"] as? Bool == true)
    #expect(try #require(wire["stalled_bytes"] as? Int) < declared)
}

private final class StallFrames: FrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    func consume(_ frame: BorrowedFrame) { lock.withLock { frames += 1 } }
    var count: Int { lock.withLock { frames } }
}
