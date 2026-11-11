import Foundation
import RemoraControl
import RemoraCore

extension CommandLineController {
    func resolveConnection(_ target: String) throws -> Connection {
        let matches: [Connection]
        if let id = UUID(uuidString: target) {
            matches = connectionStore.connections.filter { $0.id == id }
        } else {
            matches = connectionStore.connections.filter { $0.name.caseInsensitiveCompare(target) == .orderedSame }
        }
        guard let connection = matches.first else { throw ControlFailure(.notFound, "Connection not found.") }
        guard matches.count == 1 else { throw ControlFailure(.ambiguousTarget, "Several connections have that name.") }
        return connection
    }

    func connectionInfo(_ connection: Connection, metadataSaved: Bool = false) throws -> ControlValue {
        guard case .object(var fields) = try ControlValue.encoding(connection) else { return .null }
        fields["hasPassword"] = .bool(try credential({ try credentialStore.password(for: connection.id) != nil }, metadataSaved: metadataSaved))
        fields["session"] = sessions.session(for: connection.id).map { .string($0.attemptID.uuidString) } ?? .null
        return .object(fields)
    }

    func credential<T>(_ operation: () throws -> T, metadataSaved: Bool = false) throws -> T {
        do { return try operation() } catch {
            throw ControlFailure(
                .credentialFailed,
                metadataSaved
                    ? "Connection metadata was saved, but the password operation failed."
                    : "The password operation failed.",
                details: .object(["recordSaved": .bool(metadataSaved)]))
        }
    }

    private func store(_ operation: () throws -> Void) throws {
        do { try operation() } catch { throw ControlFailure(.storeFailed, "Could not save connection metadata.") }
    }

    func savePassword(_ password: String, id: UUID, metadataSaved: Bool = false) throws {
        try credential(
            {
                if password.isEmpty { try credentialStore.removePassword(for: id) } else { try credentialStore.setPassword(password, for: id) }
            }, metadataSaved: metadataSaved)
    }

    func handleConnection(_ request: ControlRequest) throws -> ControlValue {
        let fields: Set<String> = ["kind", "host", "name", "port", "username", "domain", "resolution", "vncMode", "password"]
        let allowed: Set<String>
        switch request.command {
        case "connection.list": allowed = ["search"]
        case "connection.create": allowed = fields
        case "connection.update": allowed = fields.union(["connection", "clearPassword"])
        case "connection.duplicate": allowed = ["connection", "name"]
        case "connection.get", "connection.delete", "connection.password.clear": allowed = ["connection"]
        case "connection.password.set": allowed = ["connection", "password"]
        default: throw ControlFailure(.unknownCommand, "Unknown connection command.")
        }
        try request.validateArguments(allowed)
        if request.command == "connection.list" {
            let search = try request.string("search")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Listing never reads passwords or their Keychain items.
            let matches = connectionStore.connections.filter {
                search.isEmpty || $0.name.localizedStandardContains(search) || $0.host.localizedStandardContains(search)
                    || $0.username.localizedStandardContains(search)
            }
            return .array(try matches.map { try .encoding($0) })
        }
        if request.command == "connection.create" || request.command == "connection.update" {
            let isNew = request.command == "connection.create"
            let original = try isNew ? Connection(name: "", host: "", username: "") : resolveConnection(request.string("connection", required: true)!)
            let kind: Connection.Kind?
            if let text = try request.string("kind") {
                guard let parsed = Connection.Kind(rawValue: text) else { throw ControlFailure(.invalidArgument, "Protocol must be rdp or vnc.") }
                kind = parsed
            } else {
                kind = nil
            }
            let vncMode: VNCMode?
            if let text = try request.string("vncMode") {
                guard let parsed = VNCMode(rawValue: text) else { throw ControlFailure(.invalidArgument, "VNC mode must be standard or apple.") }
                vncMode = parsed
            } else {
                vncMode = nil
            }
            let password = try request.string("password")
            let clear = try request.flag("clearPassword")
            guard password == nil || !clear else { throw ControlFailure(.invalidArgument, "Choose a password or clearPassword.") }
            let port: Int?
            if let value = request.arguments["port"] {
                guard case .number(let number) = value, number >= 1, number <= 65535, number.rounded() == number else {
                    throw ControlFailure(.invalidArgument, "Port must be 1 to 65535.")
                }
                port = Int(number)
            } else {
                port = nil
            }
            let patch = try ConnectionPatch(
                name: request.string("name"), host: request.string("host", required: isNew),
                port: port, username: request.string("username"), domain: request.string("domain"),
                resolution: request.string("resolution").map { try parseResolution($0) }, kind: kind, vncMode: vncMode)
            let updated: Connection
            do { updated = try patch.applying(to: original) } catch { throw ControlFailure(.invalidArgument, error.localizedDescription) }
            try store { if isNew { try connectionStore.add(updated) } else { try connectionStore.update(updated) } }
            sessions.update(updated)
            if let password {
                try savePassword(password, id: updated.id, metadataSaved: true)
            } else if clear {
                try savePassword("", id: updated.id, metadataSaved: true)
            }
            return try connectionInfo(updated, metadataSaved: true)
        }
        let original = try resolveConnection(request.string("connection", required: true)!)
        switch request.command {
        case "connection.get": return try connectionInfo(original)
        case "connection.duplicate":
            let password = try credential { try credentialStore.password(for: original.id) }
            var copy = original
            copy.id = UUID()
            copy.lastConnected = nil
            copy.name = try request.string("name") ?? original.name + " copy"
            copy = try ConnectionPatch(name: copy.name).applying(to: copy)
            try store { try connectionStore.add(copy) }
            if let password { try savePassword(password, id: copy.id, metadataSaved: true) }
            return try connectionInfo(copy, metadataSaved: true)
        case "connection.delete":
            try store { try connectionStore.delete(ids: [original.id]) }
            try savePassword("", id: original.id, metadataSaved: true)
            return .object(["deleted": .bool(true), "connection": .string(original.id.uuidString)])
        case "connection.password.set": try savePassword(request.string("password", required: true)!, id: original.id)
        case "connection.password.clear": try savePassword("", id: original.id)
        default: throw ControlFailure(.unknownCommand, "Unknown connection command.")
        }
        return try connectionInfo(original)
    }
}

func parseResolution(_ text: String) throws -> ConnectionResolution {
    let value = try ControlResolution(text)
    if let width = value.width, let height = value.height { return .fixed(width: width, height: height) }
    return .fitToWindow
}
