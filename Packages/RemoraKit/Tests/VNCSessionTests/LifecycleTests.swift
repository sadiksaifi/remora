import Darwin
import Foundation
import RemoraCore
import Testing
import VNCSession

/// A loopback network boundary that stalls inside a greeting or raw rectangle.
/// No TLS, credentials, external server, saved settings, or Keychain is used.
private final class StalledPeer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var accepted: Int32 = -1
    private var closing = false
    private var clientBytes: [UInt8] = []
    private var clientPrefixRead = false
    private var receivedResizes: [DesktopSize] = []

    init(partialFrame: Bool, stallRectangle: Bool = true) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { close(listener); throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        Thread { [self] in
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let ready = lock.withLock {
                if closing { close(client); return false }
                accepted = client
                return true
            }
            guard ready else { return }
            if partialFrame {
                // RFB 3.8, None, SecurityResult success, 16x16 ServerInit.
                var bytes = Array("RFB 003.008\n".utf8) + [1, 1, 0, 0, 0, 0]
                bytes += [0,16,0,16, 32,24,0,1, 0,255,0,255,0,255, 16,8,0, 0,0,0, 0,0,0,0]
                // One raw rectangle, with only 2 of its required 1024 pixels' bytes.
                if stallRectangle { bytes += [0,0,0,1, 0,0,0,0,0,16,0,16, 0,0,0,0, 1,2] }
                bytes.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
            } else {
                let bytes = Array("RFB 003.".utf8)
                bytes.withUnsafeBytes { _ = Darwin.send(client, $0.baseAddress, $0.count, 0) }
            }
        }.start()
    }
    func sendLayout(width: UInt8, origin: UInt8, result: UInt8) {
        let bytes: [UInt8] = [0,0,0,1, 0,origin,0,result,0,width,0,16, 255,255,254,204,
            1,0,0,0, 0,0,0,1, 0,0,0,0, 0,width,0,16, 0,0,0,0]
        lock.withLock {
            if accepted >= 0 { bytes.withUnsafeBytes { _ = Darwin.send(accepted, $0.baseAddress, $0.count, 0) } }
        }
    }
    func resizeRequests() -> [DesktopSize] {
        lock.withLock {
            guard accepted >= 0 else { return receivedResizes }
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = recv(accepted, &bytes, bytes.count, MSG_DONTWAIT)
                guard count > 0 else { break }
                clientBytes.append(contentsOf: bytes.prefix(count))
            }
            // Client version, None selection, and ClientInit precede normal messages.
            if !clientPrefixRead {
                guard clientBytes.count >= 14 else { return receivedResizes }
                clientBytes.removeFirst(14)
                clientPrefixRead = true
            }
            while clientBytes.count >= 8 {
                func word(_ offset: Int) -> Int { Int(clientBytes[offset]) << 8 | Int(clientBytes[offset + 1]) }
                let length: Int
                switch clientBytes[0] {
                case 0: length = 20 // SetPixelFormat
                case 2: length = 4 + word(2) * 4 // SetEncodings
                case 3: length = 10 // FramebufferUpdateRequest
                case 251: length = 8 + Int(clientBytes[6]) * 16 // SetDesktopSize
                default: return receivedResizes
                }
                guard clientBytes.count >= length else { return receivedResizes }
                if clientBytes[0] == 251 { receivedResizes.append(.init(width: word(2), height: word(4))) }
                clientBytes.removeFirst(length)
            }
            return receivedResizes
        }
    }
    func stop() {
        lock.withLock {
            guard !closing else { return }
            closing = true
            shutdown(listener, SHUT_RDWR); close(listener)
            if accepted >= 0 { shutdown(accepted, SHUT_RDWR); close(accepted); accepted = -1 }
        }
    }
}
private struct DiscardFrames: FrameSink { func consume(_ frame: BorrowedFrame) {} }

@Test @MainActor func vncCancellationInterruptsIncompleteGreeting() async throws {
    let peer = try StalledPeer(partialFrame: false)
    defer { peer.stop() }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: DiscardFrames())
    session.connect()
    let fallback = Task { do { try await Task.sleep(for: .seconds(2)); peer.stop() } catch {} }
    defer { fallback.cancel() }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    session.disconnect()
    var terminals: [DisconnectReason?] = []
    for await event in session.events {
        if case .stateChanged(.disconnected(let reason)) = event { terminals.append(reason) }
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(terminals == [.cancelledByUser])
}

@Test @MainActor func vncPartialFrameCancellationWakesAdmittedAgentSend() async throws {
    let peer = try StalledPeer(partialFrame: true)
    defer { peer.stop() }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: DiscardFrames())
    session.connect()
    let fallback = Task { do { try await Task.sleep(for: .seconds(3)); peer.stop(); session.disconnect() } catch {} }
    defer { fallback.cancel() }
    var request: (any AgentInputRequest)?
    var send: Task<Void, any Error>?
    var started = ContinuousClock.now
    for await event in session.events {
        if case .stateChanged(.connected) = event {
            try await Task.sleep(for: .milliseconds(100))
            let input = try #require(session.beginAgentInput())
            request = input
            let key = try PhysicalKey.chord("ShiftLeft")[0]
            send = Task { try await input.send(.key(key, down: true), deadline: .now.advanced(by: .seconds(2))) }
            try await Task.sleep(for: .milliseconds(50))
            started = .now
            session.disconnect()
        }
    }
    #expect(started.duration(to: .now) < .seconds(1))
    let admitted = try #require(send)
    do { try await admitted.value; Issue.record("A blocked send must fail when the session ends.") }
    catch let failure as AgentInputFailure { #expect(failure == .sessionEnded) }
    #expect(started.duration(to: .now) < .seconds(1))
    #expect(await request?.finish() == false)
}


@Test @MainActor func vncForwardedResizePreservesCapabilityUntilActualGeometry() async throws {
    let peer = try StalledPeer(partialFrame: true, stallRectangle: false)
    defer { peer.stop() }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: DiscardFrames())
    let fallback = Task { do { try await Task.sleep(for: .seconds(3)); peer.stop(); session.disconnect() } catch {} }
    defer { fallback.cancel() }
    var sizes: [DesktopSize] = []
    var capabilitySeen = false
    var completed = false
    session.connect()
    for await event in session.events {
        switch event {
        case .stateChanged(.connected): peer.sendLayout(width: 16, origin: 0, result: 0)
        case .dynamicResizeChanged(let supported):
            if capabilitySeen { #expect(supported) }
            if !capabilitySeen, supported {
                capabilitySeen = true
                session.requestResize(.init(width: 32, height: 16), scale: 1)
                try await Task.sleep(for: .milliseconds(30))
                peer.sendLayout(width: 32, origin: 1, result: 4)
                try await Task.sleep(for: .milliseconds(100))
                #expect(session.supportsDynamicResize)
                // The later applied geometry deliberately differs from the request.
                peer.sendLayout(width: 24, origin: 0, result: 0)
            }
        case .desktopSizeChanged(let size, let requested):
            sizes.append(size)
            #expect(!requested)
            if size.width == 24 { completed = true; session.disconnect() }
        default: break
        }
    }
    #expect(completed)
    #expect(!sizes.contains(.init(width: 32, height: 16)))
    #expect(sizes.last == .init(width: 24, height: 16))
}

@Test @MainActor func vncAdministrativeResizeDenialSurvivesLayoutNotifications() async throws {
    let peer = try StalledPeer(partialFrame: true, stallRectangle: false)
    defer { peer.stop() }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: DiscardFrames())
    let fallback = Task { do { try await Task.sleep(for: .seconds(3)); peer.stop(); session.disconnect() } catch {} }
    defer { fallback.cancel() }
    var capabilities: [Bool] = []
    var sizes: [DesktopSize] = []
    session.connect()
    for await event in session.events {
        switch event {
        case .stateChanged(.connected): peer.sendLayout(width: 16, origin: 0, result: 0)
        case .dynamicResizeChanged(let supported):
            capabilities.append(supported)
            if capabilities.count == 1, supported {
                session.requestResize(.init(width: 32, height: 16), scale: 1)
                try await Task.sleep(for: .milliseconds(30))
                peer.sendLayout(width: 32, origin: 1, result: 1)
                peer.sendLayout(width: 16, origin: 0, result: 0)
                try await Task.sleep(for: .milliseconds(100))
                #expect(!session.supportsDynamicResize)
                #expect(session.maximumResizeArea == nil)
                session.disconnect()
            }
        case .desktopSizeChanged(let size, _): sizes.append(size)
        default: break
        }
    }
    #expect(capabilities == [true, false])
    #expect(!sizes.contains(.init(width: 32, height: 16)))
    #expect(sizes.last == .init(width: 16, height: 16))
}


@Test @MainActor func vncResizeBackToConfirmedSizeIsSentWhileEarlierResizeIsForwarded() async throws {
    let peer = try StalledPeer(partialFrame: true, stallRectangle: false)
    defer { peer.stop() }
    let session = VNCSession(configuration: .init(host: "127.0.0.1", port: peer.port, username: "", desktopSize: .init(width: 16, height: 16)), frameSink: DiscardFrames())
    let fallback = Task { do { try await Task.sleep(for: .seconds(3)); peer.stop(); session.disconnect() } catch {} }
    defer { fallback.cancel() }
    var requests: [DesktopSize] = []
    session.connect()
    for await event in session.events {
        switch event {
        case .stateChanged(.connected): peer.sendLayout(width: 16, origin: 0, result: 0)
        case .dynamicResizeChanged(true):
            session.requestResize(.init(width: 32, height: 16), scale: 1)
            let firstDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while peer.resizeRequests().isEmpty, ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(5)) }
            peer.sendLayout(width: 32, origin: 1, result: 4)
            session.requestResize(.init(width: 16, height: 16), scale: 1)
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
            while peer.resizeRequests().count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            requests = peer.resizeRequests()
            session.disconnect()
        default: break
        }
    }
    #expect(requests == [.init(width: 32, height: 16), .init(width: 16, height: 16)])
}
