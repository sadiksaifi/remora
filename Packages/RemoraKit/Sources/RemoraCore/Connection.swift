import Foundation

/// Remote pixels for a fixed desktop, or a desktop that follows the local window.
public enum ConnectionResolution: Codable, Sendable, Hashable {
    case fitToWindow
    case fixed(width: Int, height: Int)

    public var isValid: Bool {
        switch self {
        case .fitToWindow: true
        case .fixed(let width, let height):
            (200...8192).contains(width) && (200...8192).contains(height) && width.isMultiple(of: 2)
        }
    }
}

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
    public var resolution: ConnectionResolution
    public var lastConnected: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = Connection.defaultPort,
        username: String,
        domain: String? = nil,
        kind: Kind = .rdp,
        lastConnected: Date? = nil,
        resolution: ConnectionResolution = .fitToWindow
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.kind = kind
        self.lastConnected = lastConnected
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, domain, kind, lastConnected, resolution
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        username = try values.decode(String.self, forKey: .username)
        domain = try values.decodeIfPresent(String.self, forKey: .domain)
        kind = try values.decode(Kind.self, forKey: .kind)
        lastConnected = try values.decodeIfPresent(Date.self, forKey: .lastConnected)
        resolution = try values.decodeIfPresent(ConnectionResolution.self, forKey: .resolution) ?? .fitToWindow
    }

    public var displayAddress: String {
        port == Self.defaultPort ? host : "\(host):\(port)"
    }
}
