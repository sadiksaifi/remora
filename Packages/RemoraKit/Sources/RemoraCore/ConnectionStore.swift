import Foundation
import Observation

@MainActor @Observable
public final class ConnectionStore {
    public enum StorageError: Error {
        case loadFailed(URL, underlying: any Error)
        case quarantineFailed(URL, underlying: any Error)
        case saveFailed(URL, underlying: any Error)
    }

    public private(set) var connections: [Connection]
    private let fileURL: URL

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        connections = []
        let data: Data
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            data = try Data(contentsOf: fileURL)
        } catch {
            throw StorageError.loadFailed(fileURL, underlying: error)
        }

        do {
            connections = try JSONDecoder().decode([Connection].self, from: data)
        } catch {
            var archiveURL = fileURL.appendingPathExtension("corrupt")
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                archiveURL = archiveURL.appendingPathExtension(UUID().uuidString)
            }
            do {
                try FileManager.default.moveItem(at: fileURL, to: archiveURL)
            } catch {
                throw StorageError.quarantineFailed(fileURL, underlying: error)
            }
        }
    }

    public func add(_ connection: Connection) throws {
        try save(connections + [connection])
    }

    public func update(_ connection: Connection) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connections
        updated[index] = connection
        try save(updated)
    }

    public func delete(ids: Set<UUID>) throws {
        try save(connections.filter { !ids.contains($0.id) })
    }

    /// Takes every state a connection's session reports. Only a session that reaches the connected state sets
    /// the last-connected date, so an attempt that is refused, times out or fails its credentials leaves it alone.
    public func sessionChanged(to state: SessionState, id: UUID) throws {
        guard state == .connected, var connection = connections.first(where: { $0.id == id }) else { return }
        connection.lastConnected = Date()
        try update(connection)
    }

    private func save(_ updated: [Connection]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(updated).write(to: fileURL, options: .atomic)
            connections = updated
        } catch {
            throw StorageError.saveFailed(fileURL, underlying: error)
        }
    }
}
