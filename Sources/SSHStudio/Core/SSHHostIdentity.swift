import CryptoKit
import Foundation

struct SSHHostEndpoint: Codable, Hashable, Identifiable {
    var hostname: String
    var port: Int
    var hostKeyAlias: String?
    var profileID: UUID?

    var id: String {
        [knownHostsName, "\(port)", hostKeyAlias ?? "", profileID?.uuidString ?? ""].joined(separator: "|")
    }

    var displayName: String {
        hostKeyAlias ?? hostname
    }

    var knownHostsName: String {
        let host = hostKeyAlias?.isEmpty == false ? hostKeyAlias! : hostname
        if port == 22 { return host }
        if isIPv6(host) {
            return "[\(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))]:\(port)"
        }
        return "[\(host)]:\(port)"
    }

    var key: String {
        "\(knownHostsName)|\(port)"
    }

    init(hostname: String, port: Int = 22, hostKeyAlias: String? = nil, profileID: UUID? = nil) {
        self.hostname = hostname
        self.port = port
        self.hostKeyAlias = hostKeyAlias
        self.profileID = profileID
    }

    init(session: Session) {
        let host = session.sshConfigAlias.isEmpty ? session.host : session.sshConfigAlias
        self.init(hostname: host, port: session.port, hostKeyAlias: nil, profileID: session.id)
    }

    private func isIPv6(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed.contains(":")
    }
}

enum SSHHostKeyAlgorithm: String, Codable, CaseIterable, Hashable {
    case ed25519 = "ssh-ed25519"
    case rsa = "ssh-rsa"
    case ecdsa256 = "ecdsa-sha2-nistp256"
    case ecdsa384 = "ecdsa-sha2-nistp384"
    case ecdsa521 = "ecdsa-sha2-nistp521"
    case skEd25519 = "sk-ssh-ed25519@openssh.com"
    case skEcdsa256 = "sk-ecdsa-sha2-nistp256@openssh.com"
    case unknown

    init(rawOpenSSHValue: String) {
        self = Self(rawValue: rawOpenSSHValue) ?? .unknown
    }
}

struct SSHHostFingerprint: Codable, Hashable {
    var sha256: String

    init(sha256: String) {
        self.sha256 = sha256
    }

    static func computeSHA256(publicKeyBase64: String) throws -> SSHHostFingerprint {
        guard let keyData = Data(base64Encoded: publicKeyBase64) else {
            throw SSHHostKeyError.malformedKey
        }
        let digest = SHA256.hash(data: keyData)
        let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return SSHHostFingerprint(sha256: "SHA256:\(encoded)")
    }
}

enum SSHHostTrustState: Codable, Hashable {
    case unchecked
    case checking
    case trustedBySystem
    case trustedBySSHStudio
    case trustedByOpenSSHConfiguration
    case unknown([SSHHostKeyCandidate])
    case changed(previous: SSHHostKeyRecord, presented: SSHHostKeyCandidate)
    case unavailable(String)
    case failed(String)
}

enum SSHHostTrustSource: String, Codable, Hashable {
    case system
    case sshStudio
}

struct SSHHostIdentity: Codable, Hashable {
    var endpoint: SSHHostEndpoint
    var algorithm: SSHHostKeyAlgorithm
    var fingerprint: SSHHostFingerprint
}

struct SSHHostKeyCandidate: Codable, Hashable, Identifiable {
    var id: String { "\(endpoint.key)|\(algorithm.rawValue)|\(fingerprint.sha256)" }
    var endpoint: SSHHostEndpoint
    var algorithm: SSHHostKeyAlgorithm
    var publicKey: String
    var fingerprint: SSHHostFingerprint

    var knownHostsLine: String {
        "\(endpoint.knownHostsName) \(algorithm.rawValue) \(publicKey)"
    }
}

struct SSHHostKeyRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var endpoint: SSHHostEndpoint
    var algorithm: SSHHostKeyAlgorithm
    var publicKey: String
    var fingerprint: SSHHostFingerprint
    var source: SSHHostTrustSource
    var dateAdded: Date?
    var profileIDs: [UUID]

    init(
        id: UUID = UUID(),
        endpoint: SSHHostEndpoint,
        algorithm: SSHHostKeyAlgorithm,
        publicKey: String,
        fingerprint: SSHHostFingerprint,
        source: SSHHostTrustSource,
        dateAdded: Date? = nil,
        profileIDs: [UUID] = []
    ) {
        self.id = id
        self.endpoint = endpoint
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.source = source
        self.dateAdded = dateAdded
        self.profileIDs = profileIDs
    }

    init(candidate: SSHHostKeyCandidate, source: SSHHostTrustSource, dateAdded: Date? = Date()) {
        self.init(
            endpoint: candidate.endpoint,
            algorithm: candidate.algorithm,
            publicKey: candidate.publicKey,
            fingerprint: candidate.fingerprint,
            source: source,
            dateAdded: dateAdded,
            profileIDs: candidate.endpoint.profileID.map { [$0] } ?? []
        )
    }
}

enum SSHHostKeyError: LocalizedError, Equatable {
    case invalidEndpoint
    case malformedKey
    case malformedScanOutput
    case oversizedOutput
    case timeout
    case cancelled
    case ambiguous
    case changed
    case notFound
    case store(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Host endpoint is invalid."
        case .malformedKey: return "Host key is malformed."
        case .malformedScanOutput: return "Host-key scan output is malformed."
        case .oversizedOutput: return "Host-key scan output is too large."
        case .timeout: return "Host-key scan timed out."
        case .cancelled: return "Host-key verification was cancelled."
        case .ambiguous: return "Host-key verification returned ambiguous results."
        case .changed: return "Host identity changed."
        case .notFound: return "Host key was not found."
        case .store(let message): return message
        }
    }
}
