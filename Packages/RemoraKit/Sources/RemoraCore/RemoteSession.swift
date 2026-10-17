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

    public init(
        host: String, port: UInt16 = 3389, username: String, domain: String = "",
        password: String? = nil, desktopSize: DesktopSize, scaleFactor: Double = 1
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.password = password
        self.desktopSize = desktopSize
        self.scaleFactor = scaleFactor
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
    case desktopSizeChanged(DesktopSize)
    case credentialsChallenge(CredentialsChallenge)
    case trustChallenge(TrustChallenge)
}

/// A session is single-use. Repeated connect/disconnect calls are harmless.
/// Events finish after the terminal disconnected event. Consume the stream once.
public protocol RemoteSession: AnyObject, Sendable {
    var events: AsyncStream<SessionEvent> { get }
    func connect()
    func disconnect()
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
