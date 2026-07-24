import Foundation

@MainActor
class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []

    private let key = "saved_sessions"
    private let backupKey = "saved_sessions_backup_schema0"
    private let migrationMarkerKey = "saved_sessions_migrated_schema2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = SSHStudioDefaults.shared) {
        self.defaults = defaults
        load()
    }

    func add(_ session: Session) {
        sessions.append(session)
        save()
    }

    func update(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? SessionPersistenceMigrator.encode(sessions) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let result = try SessionPersistenceMigrator.decode(data)
            sessions = result.sessions
            if result.needsWrite {
                migrateLegacyPayload(originalData: data, migratedSessions: result.sessions)
            }
        } catch {
            ConnectionLog.shared.log(
                "Saved sessions could not be loaded: \(DiagnosticRedactor.redact(error.localizedDescription))",
                level: .error
            )
        }
    }

    private func migrateLegacyPayload(originalData: Data, migratedSessions: [Session]) {
        guard let migratedData = try? SessionPersistenceMigrator.encode(migratedSessions) else { return }
        if defaults.data(forKey: backupKey) == nil {
            defaults.set(originalData, forKey: backupKey)
        }
        defaults.set(migratedData, forKey: key)
        defaults.set(true, forKey: migrationMarkerKey)
    }

}
