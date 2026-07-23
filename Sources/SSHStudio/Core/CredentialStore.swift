import Foundation
import Security

struct CredentialReference: Codable, Hashable, Identifiable {
    let id: String

    init(id: String = UUID().uuidString) {
        self.id = id
    }
}

struct CredentialSecret {
    private let storage: Data

    init(data: Data) {
        self.storage = data
    }

    init(string: String) {
        self.storage = Data(string.utf8)
    }

    func dataValue() -> Data {
        storage
    }
}

enum CredentialStoreError: LocalizedError, Equatable {
    case notFound
    case duplicate
    case keychainStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .notFound: return "Credential was not found."
        case .duplicate: return "Credential already exists."
        case .keychainStatus(let status): return "Keychain operation failed with status \(status)."
        case .invalidData: return "Credential data is invalid."
        }
    }
}

protocol CredentialStore {
    func create(_ secret: CredentialSecret, label: String) throws -> CredentialReference
    func read(_ reference: CredentialReference) throws -> CredentialSecret
    func update(_ reference: CredentialReference, secret: CredentialSecret) throws
    func delete(_ reference: CredentialReference) throws
}

final class InMemoryCredentialStore: CredentialStore {
    private var values: [CredentialReference: CredentialSecret] = [:]

    func create(_ secret: CredentialSecret, label: String) throws -> CredentialReference {
        let reference = CredentialReference()
        values[reference] = secret
        return reference
    }

    func read(_ reference: CredentialReference) throws -> CredentialSecret {
        guard let value = values[reference] else { throw CredentialStoreError.notFound }
        return value
    }

    func update(_ reference: CredentialReference, secret: CredentialSecret) throws {
        guard values[reference] != nil else { throw CredentialStoreError.notFound }
        values[reference] = secret
    }

    func delete(_ reference: CredentialReference) throws {
        guard values.removeValue(forKey: reference) != nil else { throw CredentialStoreError.notFound }
    }
}

final class KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = "com.sshstudio.app.credentials") {
        self.service = service
    }

    func create(_ secret: CredentialSecret, label: String) throws -> CredentialReference {
        let reference = CredentialReference()
        var query = baseQuery(reference)
        query[kSecValueData as String] = secret.dataValue()
        query[kSecAttrLabel as String] = label
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status != errSecDuplicateItem else { throw CredentialStoreError.duplicate }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
        return reference
    }

    func read(_ reference: CredentialReference) throws -> CredentialSecret {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw CredentialStoreError.notFound }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
        guard let data = item as? Data else { throw CredentialStoreError.invalidData }
        return CredentialSecret(data: data)
    }

    func update(_ reference: CredentialReference, secret: CredentialSecret) throws {
        let status = SecItemUpdate(
            baseQuery(reference) as CFDictionary,
            [kSecValueData as String: secret.dataValue()] as CFDictionary
        )
        guard status != errSecItemNotFound else { throw CredentialStoreError.notFound }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
    }

    func delete(_ reference: CredentialReference) throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status != errSecItemNotFound else { throw CredentialStoreError.notFound }
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
    }

    private func baseQuery(_ reference: CredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.id
        ]
    }
}

/*
 Future password/passphrase injection must use a signed SSH_ASKPASS helper or
 macOS ssh-agent/UseKeychain integration. This store intentionally does not feed
 credentials to /usr/bin/ssh in Phase 1.
 */
