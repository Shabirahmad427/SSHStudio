import Foundation

struct MigrationCheckReport: Codable, Equatable {
    var preferencesPresent: Bool
    var savedProfileCount: Int
    var sourceSchemaVersions: [Int]
    var migratedSchemaVersion: Int
    var profilesWithStableUUID: Int
    var credentialReferenceCount: Int
    var managedHostKeyStorePresent: Bool
    var managedHostKeyRecordCount: Int
    var terminalSettingCount: Int
    var appearanceSettingPresent: Bool
    var updateSettingCount: Int
    var errors: [String]

    var succeeded: Bool { errors.isEmpty }
}

enum MigrationCheckCommand {
    static let argument = "--migration-check"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.contains(argument)
    }

    static func runAndPrint(
        defaults: UserDefaults = .standard,
        hostKeyStoreURL: URL = ManagedHostKeyStore.defaultStoreURL()
    ) -> Int32 {
        let report = run(defaults: defaults, hostKeyStoreURL: hostKeyStoreURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report), let output = String(data: data, encoding: .utf8) {
            print(output)
        } else {
            print("{\"errors\":[\"Failed to encode migration-check report.\"]}")
            return 2
        }
        return report.succeeded ? 0 : 1
    }

    static func run(
        defaults: UserDefaults,
        hostKeyStoreURL: URL
    ) -> MigrationCheckReport {
        var report = MigrationCheckReport(
            preferencesPresent: defaults.dictionaryRepresentation().isEmpty == false,
            savedProfileCount: 0,
            sourceSchemaVersions: [],
            migratedSchemaVersion: PersistedSessionProfile.currentSchemaVersion,
            profilesWithStableUUID: 0,
            credentialReferenceCount: 0,
            managedHostKeyStorePresent: FileManager.default.fileExists(atPath: hostKeyStoreURL.path),
            managedHostKeyRecordCount: 0,
            terminalSettingCount: defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("terminal_") }.count,
            appearanceSettingPresent: defaults.object(forKey: "app_appearance") != nil,
            updateSettingCount: defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("update_") || $0.hasPrefix("updates_") }.count,
            errors: []
        )

        if let payload = defaults.data(forKey: "saved_sessions") {
            do {
                report.sourceSchemaVersions = sourceSchemaVersions(in: payload)
                let result = try SessionPersistenceMigrator.decode(payload)
                report.savedProfileCount = result.sessions.count
                report.profilesWithStableUUID = result.sessions.filter { $0.id.uuidString.isEmpty == false }.count
                report.credentialReferenceCount = result.sessions.filter {
                    !($0.authentication.credentialReferenceID ?? $0.credentialReferenceID).isEmpty
                }.count
                try result.sessions.forEach { session in
                    guard session.schemaVersion == PersistedSessionProfile.currentSchemaVersion else {
                        throw SessionMigrationError.unsupportedVersion(session.schemaVersion)
                    }
                    guard session.id.uuidString.isEmpty == false else {
                        throw SessionMigrationError.emptyName(session.id)
                    }
                    if let reference = session.authentication.credentialReferenceID,
                       UUID(uuidString: reference) == nil {
                        throw SessionMigrationError.invalidProfile(session.id, "Credential reference is not a UUID.")
                    }
                }
            } catch {
                report.errors.append(DiagnosticRedactor.redact(error.localizedDescription))
            }
        }

        if report.managedHostKeyStorePresent {
            do {
                let data = try Data(contentsOf: hostKeyStoreURL)
                guard data.count < 2_000_000 else { throw SSHHostKeyError.oversizedOutput }
                let payload = try JSONDecoder().decode(ManagedHostKeyPayload.self, from: data)
                report.managedHostKeyRecordCount = payload.records.count
            } catch {
                report.errors.append(DiagnosticRedactor.redact(error.localizedDescription))
            }
        }

        return report
    }

    private static func sourceSchemaVersions(in payload: Data) -> [Int] {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
            return []
        }
        let versions = object.compactMap { profile -> Int? in
            if let version = profile["schemaVersion"] as? Int { return version }
            return (profile["session"] as? [String: Any])?["schemaVersion"] as? Int
        }
        return Array(Set(versions)).sorted()
    }
}

private struct ManagedHostKeyPayload: Codable {
    var version: Int
    var records: [SSHHostKeyRecord]
}
