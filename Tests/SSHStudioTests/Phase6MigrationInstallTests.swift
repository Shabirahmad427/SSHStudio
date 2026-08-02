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
        #expect(script.contains("--backup-dir"))
        #expect(script.contains("--allow-invalid-existing-signature"))
        #expect(script.contains("verify_matching_sha256"))
        #expect(script.contains("package_inputs = ("))
        #expect(script.contains("\"Scripts/build-app.sh\""))
        #expect(script.contains("\"Scripts/sshstudio_metadata.py\""))
        #expect(script.contains("Repository has uncommitted package-input changes"))
        #expect(script.contains("Refusing to install over a running SSH Studio instance"))
        #expect(!script.contains("rm -rf"))
        #expect(script.contains("ditto"))
        #expect(script.contains("SSHStudioAskPass"))
        #expect(script.contains("SwiftTerm_SwiftTerm.bundle/Shaders.metal"))
    }

    @Test func installerInvalidSignatureOverridePolicyIsExplicitAndBounded() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = root.appendingPathComponent("Scripts/install-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("verify_app \"$CANDIDATE\""))
        #expect(script.contains("verify_existing_app_or_allowed_invalid \"$DESTINATION_APP\""))
        #expect(script.contains("Existing installed app has an invalid signature"))
        #expect(script.contains("[[ \"$ALLOW_INVALID_EXISTING_SIGNATURE\" == \"true\" ]]"))
        #expect(script.contains("EXPECTED_DESTINATION_APP=\"/Users/shabir/Applications/$APP_NAME\""))
        #expect(script.contains("destination is a symlink"))
        #expect(script.contains("installed bundle identifier is not $BUNDLE_ID"))
        #expect(script.contains("is not arm64"))
        #expect(script.contains("refuse_running_destination \"$destination\""))
        #expect(script.contains("verify_validated_rollback_source"))
        #expect(script.contains("WARNING: proceeding with invalid existing SSH Studio signature override."))
    }

    @Test func installerInvalidExistingBackupRequiresBundleHashVerification() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = root.appendingPathComponent("Scripts/install-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("file_hashes_for_bundle"))
        #expect(script.contains("installed-bundle-sha256.txt"))
        #expect(script.contains("verify_bundle_hashes_match \"$DESTINATION_APP\" \"$BACKUP_DIR/$APP_NAME\""))
        #expect(script.contains("verify_bundle_hashes_match \"$BACKUP_DIR/$APP_NAME\" \"$BACKUP_DIR/installed-before-replacement.app\""))
        #expect(script.contains("installed-signature-failure.txt"))
        #expect(script.contains("installed_signature_failure_file=installed-signature-failure.txt"))
        #expect(script.contains("rollback_instruction=Scripts/install-app.sh --rollback"))
        #expect(script.contains("verify_preserved_invalid_backup"))
        #expect(script.contains("Preserved invalid backup hashes do not match manifest."))
        #expect(script.contains("Rollback backup app is invalid and lacks verified preservation metadata."))
    }

    @Test func installerRollbackSourceValidationIsMandatoryForInvalidExistingOverride() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = root.appendingPathComponent("Scripts/install-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(script.contains("VALIDATED_ROLLBACK_SOURCE=\"/Users/shabir/Applications/SSH Studio Backups/20260724T010540Z/SSH Studio.app\""))
        #expect(script.contains("--validated-rollback-source"))
        #expect(script.contains("Validated rollback source missing"))
        #expect(script.contains("verify_existing_app \"$source\""))
        #expect(script.contains("Validated rollback source bundle identifier mismatch."))
        #expect(script.contains("validated_rollback_source=$(canonical_path \"$VALIDATED_ROLLBACK_SOURCE\")"))
    }
}
