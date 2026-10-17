import Foundation

public struct Connection: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case rdp
    }

    /// The standard RDP port.
    public static let defaultPort = 3389

    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var domain: String?
    public var kind: Kind
    public var lastConnected: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = Connection.defaultPort,
        username: String,
        domain: String? = nil,
        kind: Kind = .rdp,
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.kind = kind
        self.lastConnected = lastConnected
    }

    public var displayAddress: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }
}
