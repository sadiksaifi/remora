import Foundation

public struct DesktopSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct SessionConfiguration: Sendable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let domain: String
    public let password: String?
    public let desktopSize: DesktopSize
    /// Physical pixels per logical point, for example 2 for a Retina display.
    public let scaleFactor: Double
    public let allowsDynamicResize: Bool

    public init(
        host: String, port: UInt16 = 3389, username: String, domain: String = "",
        password: String? = nil, desktopSize: DesktopSize, scaleFactor: Double = 1,
        allowsDynamicResize: Bool = true
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.password = password
        self.desktopSize = desktopSize
        self.scaleFactor = scaleFactor
        self.allowsDynamicResize = allowsDynamicResize
    }
}

public enum DisconnectReason: Sendable, Equatable, CustomStringConvertible {
    case authenticationFailed
    case certificateRejected
    case hostNotFound
    case connectionRefused
    case connectionTimedOut
    case serverEndedSession(String)
    case protocolError(String)
    case cancelledByUser

    public var description: String {
        switch self {
        case .authenticationFailed: "Authentication failed."
        case .certificateRejected: "The server certificate was rejected."
        case .hostNotFound: "The host could not be found."
        case .connectionRefused: "The host refused the connection."
        case .connectionTimedOut: "The connection timed out or the host is unreachable."
        case .serverEndedSession(let message): "The server ended the session: \(message)"
        case .protocolError(let message): "Remote desktop error: \(message)"
        case .cancelledByUser: "The connection was cancelled."
        }
    }
}

public enum SessionState: Sendable, Equatable {
    case connecting
    case awaitingCredentials
    case awaitingTrust
    case connected
    case reconnecting(attempt: Int)
    case disconnected(DisconnectReason?)
}

/// Copies share one answer. Only the first call to respond has an effect.
public final class SessionResponder<Answer: Sendable>: Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var answer: (@Sendable (Answer) -> Void)?

    public init(_ answer: @escaping @Sendable (Answer) -> Void) {
        self.answer = answer
    }

    public func respond(_ value: Answer) {
        let callback = lock.withLock {
            let callback = answer
            answer = nil
            return callback
        }
        callback?(value)
    }
}

public struct SessionCredentials: Sendable {
    public let username: String
    public let domain: String
    public let password: String

    public init(username: String, domain: String = "", password: String) {
        self.username = username
        self.domain = domain
        self.password = password
    }
}

public struct CredentialsChallenge: Sendable {
    public enum Reason: Sendable {
        case missing
        case rejected
    }

    public let username: String
    public let domain: String
    public let reason: Reason
    /// Respond with nil to cancel the session.
    public let responder: SessionResponder<SessionCredentials?>

    public init(
        username: String, domain: String, reason: Reason,
        responder: SessionResponder<SessionCredentials?>
    ) {
        self.username = username
        self.domain = domain
        self.reason = reason
        self.responder = responder
    }
}

public enum CertificateDecision: Sendable {
    case trust
    case reject
}

public struct TrustChallenge: Sendable {
    public enum Status: Sendable, Equatable {
        case new
        case changed(oldFingerprint: String)
    }

    public let host: String
    public let port: UInt16
    public let subject: String
    public let issuer: String
    /// SHA-256 fingerprint supplied by the protocol backend.
    public let fingerprint: String
    public let status: Status
    /// Trust also stores the certificate in the backend's certificate store.
    public let responder: SessionResponder<CertificateDecision>

    public init(
        host: String, port: UInt16, subject: String, issuer: String,
        fingerprint: String, status: Status, responder: SessionResponder<CertificateDecision>
    ) {
        self.host = host
        self.port = port
        self.subject = subject
        self.issuer = issuer
        self.fingerprint = fingerprint
        self.status = status
        self.responder = responder
    }
}

public enum SessionEvent: Sendable {
    case stateChanged(SessionState)
    /// requested is true for a response to this client's resize request.
    case desktopSizeChanged(DesktopSize, requested: Bool = false)
    case dynamicResizeChanged(Bool)
    case cursorChanged(RemoteCursor)
    case clipboardChanged(revision: UInt64, status: RemoteClipboard.Status)
    case credentialsChallenge(CredentialsChallenge)
    case trustChallenge(TrustChallenge)
}

/// A session is single-use. Repeated connect/disconnect calls are harmless.
/// Events finish after the terminal disconnected event. Consume the stream once.
public protocol RemoteSession: AnyObject, Sendable {
    var events: AsyncStream<SessionEvent> { get }
    /// True after the server negotiates dynamic resizing, until that capability is lost.
    var supportsDynamicResize: Bool { get }
    /// Negotiated total pixel area for one resize, or nil when unavailable.
    var maximumResizeArea: UInt64? { get }
    /// Requests backing pixels and pixels per point. Ignored until resizing is supported.
    /// Only desktopSizeChanged confirms the resulting size.
    func requestResize(_ size: DesktopSize, scale: Double)
    /// Asks the server to stop or resume sending desktop updates, for example while the desktop is hidden.
    /// The connection, input, and clipboard continue, and the choice survives reconnection.
    /// Resuming asks the server to redraw the desktop. A server without support keeps sending updates.
    func setDisplayUpdatesEnabled(_ enabled: Bool)
    func connect()
    func disconnect()
    func sendKey(_ key: KeyInput)
    func sendPointer(position: RemotePoint, buttons: PointerButtons)
    func sendWheel(_ wheel: WheelInput)
    func synchronize(locks: LockKeys)
    /// Releases only human-owned keys and buttons, preserving agent input.
    func releaseHumanInput()
    func setLocalClipboard(text: String)
}

public struct DirtyRectangle: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Borrowed pixels in FreeRDP PIXEL_FORMAT_BGRA32 byte order: B, G, R, A.
/// Ignore alpha. The pointer is valid only during FrameSink.consume.
/// Copy all pixels you need before returning, including before dispatching work.
public struct BorrowedFrame {
    public let pixels: UnsafeRawPointer
    public let width: Int
    public let height: Int
    public let stride: Int
    public let dirtyRectangles: [DirtyRectangle]

    public init(
        pixels: UnsafeRawPointer, width: Int, height: Int, stride: Int,
        dirtyRectangles: [DirtyRectangle]
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.stride = stride
        self.dirtyRectangles = dirtyRectangles
    }
}

public protocol FrameSink: Sendable {
    /// Called synchronously on an arbitrary background thread. Must be thread-safe.
    func consume(_ frame: BorrowedFrame)
}
