import Foundation

/// Applies only the supplied fields to the latest saved connection.
public struct ConnectionPatch: Sendable {
    public var name: String?
    public var host: String?
    public var port: Int?
    public var username: String?
    /// An empty string clears the domain. Nil leaves it alone.
    public var domain: String?
    public var resolution: ConnectionResolution?
    public var kind: Connection.Kind?
    public var vncMode: VNCMode?

    public init(name: String? = nil, host: String? = nil, port: Int? = nil,
                username: String? = nil, domain: String? = nil, resolution: ConnectionResolution? = nil, kind: Connection.Kind? = nil,
                vncMode: VNCMode? = nil) {
        self.name = name; self.host = host; self.port = port
        self.username = username; self.domain = domain; self.resolution = resolution; self.kind = kind; self.vncMode = vncMode
    }

    public init(from original: Connection, to edited: Connection) {
        self.init(name: edited.name == original.name ? nil : edited.name,
                  host: edited.host == original.host ? nil : edited.host,
                  port: edited.port == original.port ? nil : edited.port,
                  username: edited.username == original.username ? nil : edited.username,
                  domain: edited.domain == original.domain ? nil : edited.domain ?? "",
                  resolution: edited.resolution == original.resolution ? nil : edited.resolution,
                  kind: edited.kind == original.kind ? nil : edited.kind,
                  vncMode: edited.vncMode == original.vncMode ? nil : edited.vncMode)
    }

    public func applying(to original: Connection) throws -> Connection {
        var result = original
        func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let host { result.host = trim(host) }
        if let name { result.name = trim(name) }
        if result.name.isEmpty { result.name = result.host }
        if let kind {
            if result.port == result.kind.defaultPort { result.port = kind.defaultPort }
            result.kind = kind
        }
        if let port { result.port = port }
        if let username { result.username = trim(username) }
        if let domain { result.domain = trim(domain).isEmpty ? nil : trim(domain) }
        if result.kind == .vnc { result.domain = nil }
        if let vncMode { result.vncMode = vncMode }
        if result.kind == .rdp {
            guard vncMode != .apple else { throw ValidationFailure(message: "Apple mode is only for VNC connections.") }
            result.vncMode = .standard
        }
        if let resolution { result.resolution = resolution }
        guard !result.host.isEmpty, !result.host.contains(where: \.isWhitespace), !result.host.contains("/") else {
            throw ValidationFailure(message: "Enter a host name or IP address without spaces or slashes.")
        }
        guard (1...65535).contains(result.port) else { throw ValidationFailure(message: "Enter a port from 1 to 65535.") }
        guard result.resolution.isValid else {
            throw ValidationFailure(message: "Enter a width and height from 200 to 8192 pixels. Width must be even.")
        }
        return result
    }

    public struct ValidationFailure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }
}
