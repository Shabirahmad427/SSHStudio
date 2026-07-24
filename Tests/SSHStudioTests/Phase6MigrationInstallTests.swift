import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 6 Migration and Install")
struct Phase6MigrationInstallTests {
    @Test func migrationCheckArgumentExitsBeforeAppLaunch() {
        #expect(MigrationCheckCommand.shouldRun(arguments: ["SSHStudio", "--migration-check"]))
        #expect(!MigrationCheckCommand.shouldRun(arguments: ["SSHStudio"]))
    }

    @Test func migrationCheckMigratesProfilesInMemoryWithoutCredentialRead() throws {
        let suite = "sshstudio-phase6-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var session = Session(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "Fixture",
            host: "example.com",
            username: "user"
        )
        session.schemaVersion = 1
        let data = try JSONEncoder().encode([PersistedSessionProfile(session: session, schemaVersion: 1)])
        defaults.set(data, forKey: "saved_sessions")
        defaults.set(17.0, forKey: "terminal_font_size")
        defaults.set("System", forKey: "app_appearance")

        let report = MigrationCheckCommand.run(
            defaults: defaults,
            hostKeyStoreURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        )

        #expect(report.succeeded)
        #expect(report.savedProfileCount == 1)
        #expect(report.sourceSchemaVersions == [1])
        #expect(report.migratedSchemaVersion == PersistedSessionProfile.currentSchemaVersion)
        #expect(report.profilesWithStableUUID == 1)
        #expect(report.credentialReferenceCount == 0)
        #expect(report.terminalSettingCount == 1)
        #expect(report.appearanceSettingPresent)
    }

    @Test func installerScriptSupportsDryRunRollbackAndAvoidsBroadDeletion() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = root.appendingPathComponent("Scripts/install-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("--dry-run"))
        #expect(script.contains("--install"))
        #expect(script.contains("--rollback"))
        #expect(script.contains("Refusing to install over a running SSH Studio instance"))
        #expect(!script.contains("rm -rf"))
        #expect(script.contains("ditto"))
        #expect(script.contains("SSHStudioAskPass"))
        #expect(script.contains("SwiftTerm_SwiftTerm.bundle/Shaders.metal"))
    }
}
