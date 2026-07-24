import Foundation

enum ProfileAuthenticationMethod: Codable, Hashable {
    case privateKey(path: String, useAgent: Bool, addKeysToAgent: Bool, useKeychain: Bool)
    case sshAgent
    case macOSKeychain(path: String, addKeysToAgent: Bool)
    case passwordCredential(referenceID: String)
    case sshConfigManaged

    enum Kind: String, Codable {
        case privateKey
        case sshAgent
        case macOSKeychain
        case passwordCredential
        case sshConfigManaged

        static let allCases: [Kind] = [
            .privateKey,
            .sshAgent,
            .macOSKeychain,
            .passwordCredential,
            .sshConfigManaged
        ]

        var displayName: String {
            switch self {
            case .privateKey: return "Private Key"
            case .sshAgent: return "SSH Agent"
            case .macOSKeychain: return "macOS Keychain / Agent"
            case .passwordCredential: return "Password Credential"
            case .sshConfigManaged: return "SSH Config"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, path, useAgent, addKeysToAgent, useKeychain, referenceID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        switch kind {
        case .privateKey:
            self = .privateKey(
                path: try values.decodeIfPresent(String.self, forKey: .path) ?? "",
                useAgent: try values.decodeIfPresent(Bool.self, forKey: .useAgent) ?? true,
                addKeysToAgent: try values.decodeIfPresent(Bool.self, forKey: .addKeysToAgent) ?? false,
                useKeychain: try values.decodeIfPresent(Bool.self, forKey: .useKeychain) ?? false
            )
        case .sshAgent:
            self = .sshAgent
        case .macOSKeychain:
            self = .macOSKeychain(
                path: try values.decodeIfPresent(String.self, forKey: .path) ?? "",
                addKeysToAgent: try values.decodeIfPresent(Bool.self, forKey: .addKeysToAgent) ?? true
            )
        case .passwordCredential:
            self = .passwordCredential(referenceID: try values.decodeIfPresent(String.self, forKey: .referenceID) ?? "")
        case .sshConfigManaged:
            self = .sshConfigManaged
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .privateKey(let path, let useAgent, let addKeysToAgent, let useKeychain):
            try values.encode(Kind.privateKey, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(useAgent, forKey: .useAgent)
            try values.encode(addKeysToAgent, forKey: .addKeysToAgent)
            try values.encode(useKeychain, forKey: .useKeychain)
        case .sshAgent:
            try values.encode(Kind.sshAgent, forKey: .kind)
        case .macOSKeychain(let path, let addKeysToAgent):
            try values.encode(Kind.macOSKeychain, forKey: .kind)
            try values.encode(path, forKey: .path)
            try values.encode(addKeysToAgent, forKey: .addKeysToAgent)
            try values.encode(true, forKey: .useKeychain)
        case .passwordCredential(let referenceID):
            try values.encode(Kind.passwordCredential, forKey: .kind)
            try values.encode(referenceID, forKey: .referenceID)
        case .sshConfigManaged:
            try values.encode(Kind.sshConfigManaged, forKey: .kind)
        }
    }

    var displayName: String {
        switch self {
        case .privateKey: return "Private Key"
        case .sshAgent: return "SSH Agent"
        case .macOSKeychain: return "macOS Keychain / Agent"
        case .passwordCredential: return "Password Credential"
        case .sshConfigManaged: return "SSH Config"
        }
    }

    var kind: Kind {
        switch self {
        case .privateKey: return .privateKey
        case .sshAgent: return .sshAgent
        case .macOSKeychain: return .macOSKeychain
        case .passwordCredential: return .passwordCredential
        case .sshConfigManaged: return .sshConfigManaged
        }
    }

    var usesAgent: Bool {
        switch self {
        case .privateKey(_, let useAgent, _, _):
            return useAgent
        case .sshAgent, .macOSKeychain:
            return true
        case .passwordCredential, .sshConfigManaged:
            return false
        }
    }

    var addsKeysToAgent: Bool {
        switch self {
        case .privateKey(_, _, let addKeysToAgent, _), .macOSKeychain(_, let addKeysToAgent):
            return addKeysToAgent
        case .sshAgent, .passwordCredential, .sshConfigManaged:
            return false
        }
    }

    var usesKeychain: Bool {
        switch self {
        case .privateKey(_, _, _, let useKeychain):
            return useKeychain
        case .macOSKeychain:
            return true
        case .sshAgent, .passwordCredential, .sshConfigManaged:
            return false
        }
    }

    var credentialReferenceID: String? {
        if case .passwordCredential(let referenceID) = self, !referenceID.isEmpty {
            return referenceID
        }
        return nil
    }

    var isNonInteractiveCapable: Bool {
        switch self {
        case .privateKey, .sshAgent, .macOSKeychain, .sshConfigManaged:
            return true
        case .passwordCredential:
            return false
        }
    }

    var privateKeyPath: String {
        switch self {
        case .privateKey(let path, _, _, _), .macOSKeychain(let path, _):
            return path
        default:
            return ""
        }
    }

    static func legacy(authMethod: Session.AuthMethod, privateKeyPath: String, credentialReferenceID: String) -> Self {
        if !credentialReferenceID.isEmpty {
            return .passwordCredential(referenceID: credentialReferenceID)
        }
        switch authMethod {
        case .privateKey:
            return .privateKey(path: privateKeyPath, useAgent: true, addKeysToAgent: false, useKeychain: false)
        case .password:
            return .sshConfigManaged
        }
    }
}

enum SSHAgentAvailability: Equatable {
    case available
    case unavailable(String)
    case unknown
}

enum AuthenticationDiagnostics {
    static func summary(for session: Session, credentialStore: CredentialStore? = nil) -> [String] {
        var lines = ["Method: \(session.authentication.displayName)"]
        if let reference = session.authentication.credentialReferenceID {
            lines.append("Credential reference: \(reference.isEmpty ? "missing" : "configured")")
            if let credentialStore {
                do {
                    _ = try credentialStore.read(CredentialReference(id: reference))
                    lines.append("Credential availability: available")
                } catch {
                    lines.append("Credential availability: unavailable")
                }
            }
        }
        let keyPath = session.authentication.privateKeyPath
        if !keyPath.isEmpty {
            lines.append("Private key file: \(FileManager.default.isReadableFile(atPath: keyPath) ? "readable" : "not readable")")
        }
        lines.append("SSH agent: \(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] == nil ? "not advertised" : "advertised")")
        return lines.map { DiagnosticRedactor.redact($0) }
    }
}
