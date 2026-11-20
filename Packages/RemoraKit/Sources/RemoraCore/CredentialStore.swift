import Foundation
import KeychainAccess

public final class CredentialStore {
    private let keychain: Keychain

    public init(service: String) {
        keychain = Keychain(service: service)
    }

    public func password(for id: UUID) throws -> String? {
        try keychain.get(id.uuidString)
    }

    public func setPassword(_ password: String, for id: UUID) throws {
        try keychain.set(password, key: id.uuidString)
    }

    public func removePassword(for id: UUID) throws {
        try keychain.remove(id.uuidString)
    }
}
