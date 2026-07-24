import Foundation

struct PersistedSessionProfile: Codable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var session: Session

    init(session: Session, schemaVersion: Int = Self.currentSchemaVersion) {
        var normalized = session
        normalized.schemaVersion = schemaVersion
        self.schemaVersion = schemaVersion
        self.session = normalized
    }
}

enum SessionMigrationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case emptyName(UUID)
    case invalidProfile(UUID, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Saved session schema version \(version) is not supported."
        case .emptyName:
            return "A saved session has an empty name."
        case .invalidProfile(_, let reason):
            return reason
        }
    }
}

struct SessionMigrationResult: Equatable {
    let sessions: [Session]
    let needsWrite: Bool
}

enum SessionPersistenceMigrator {
    static func decode(_ data: Data) throws -> SessionMigrationResult {
        let decoder = JSONDecoder()

        if let profiles = try? decoder.decode([PersistedSessionProfile].self, from: data) {
            let sessions = try profiles.map { profile in
                guard profile.schemaVersion <= PersistedSessionProfile.currentSchemaVersion else {
                    throw SessionMigrationError.unsupportedVersion(profile.schemaVersion)
                }
                var session = profile.session
                session.schemaVersion = PersistedSessionProfile.currentSchemaVersion
                try validate(session)
                return session
            }
            let needsWrite = profiles.contains { $0.schemaVersion < PersistedSessionProfile.currentSchemaVersion }
            return SessionMigrationResult(sessions: sessions, needsWrite: needsWrite)
        }

        let legacy = try decoder.decode([Session].self, from: data)
        let sessions = try legacy.map { legacySession in
            var session = legacySession
            session.schemaVersion = PersistedSessionProfile.currentSchemaVersion
            try validate(session)
            return session
        }
        return SessionMigrationResult(sessions: sessions, needsWrite: true)
    }

    static func encode(_ sessions: [Session]) throws -> Data {
        try sessions.forEach(validate)
        let profiles = sessions.map { PersistedSessionProfile(session: $0) }
        return try JSONEncoder().encode(profiles)
    }

    static func validate(_ session: Session) throws {
        guard !session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionMigrationError.emptyName(session.id)
        }
        do {
            try SSHSecurity.validate(session: session)
        } catch {
            throw SessionMigrationError.invalidProfile(session.id, error.localizedDescription)
        }
    }
}
