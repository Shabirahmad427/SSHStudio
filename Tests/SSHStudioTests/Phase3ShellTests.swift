import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 3 Shell")
@MainActor
struct Phase3ShellTests {
    @Test func sessionTabOrderIsStable() {
        #expect(SessionTab.workspaceOrder == [.terminal, .sftp, .screen, .tunnels, .sync, .transfers, .keys])
        #expect(Set(SessionTab.workspaceOrder).count == SessionTab.workspaceOrder.count)
    }

    @Test func openSessionKeepsProfileIdentityAndDefaultsToTerminal() {
        let profileID = UUID()
        let session = Session(id: profileID, name: "Fixture", host: "example.com", username: "fixture")
        let open = OpenSession(session: session)

        #expect(open.session.id == profileID)
        #expect(open.activeTab == .terminal)
        #expect(open.id != profileID)
    }

    @Test func connectionStatusStylesIncludeTextAndSymbols() {
        let connected = SSHStudioStatusStyle.connection(.connected(Date()))
        let failed = SSHStudioStatusStyle.connection(.failed(Date(), message: "redacted"))

        #expect(connected.title == "Connected")
        #expect(!connected.systemImage.isEmpty)
        #expect(failed.title == "Failed")
        #expect(!failed.systemImage.isEmpty)
    }

    @Test func defaultsUseStandardDomainWithoutPreviewOverride() {
        let defaults = SSHStudioDefaults.makeSharedDefaults(
            environment: [:],
            bundleIdentifier: SSHStudioDefaults.domain,
            bundledFixtureURL: nil
        )
        #expect(defaults === UserDefaults.standard)
    }

    @Test func defaultsCanUseExplicitPreviewSuite() {
        let suiteName = "com.sshstudio.tests.\(UUID().uuidString)"
        let defaults = SSHStudioDefaults.makeSharedDefaults(environment: [
            SSHStudioDefaults.suiteOverrideEnvironmentKey: suiteName
        ])
        defaults.set("fixture", forKey: "phase3-test")
        #expect(UserDefaults(suiteName: suiteName)?.string(forKey: "phase3-test") == "fixture")
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func previewBundleIdentifierCanLoadBundledFixtureDefaults() throws {
        let bundleID = "com.sshstudio.phase4.tests.\(UUID().uuidString)"
        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshstudio-bundled-fixture-\(UUID().uuidString).plist")
        let payload: NSDictionary = ["saved_sessions": Data("[]".utf8)]
        #expect(payload.write(to: plistURL, atomically: true))

        let defaults = SSHStudioDefaults.makeSharedDefaults(
            environment: [:],
            bundleIdentifier: bundleID,
            bundledFixtureURL: plistURL
        )

        #expect(defaults.data(forKey: "saved_sessions") == Data("[]".utf8))
        try? FileManager.default.removeItem(at: plistURL)
        UserDefaults.standard.removePersistentDomain(forName: "\(bundleID).defaults")
    }

    @Test func defaultsCanLoadVolatilePreviewPlist() throws {
        let suiteName = "com.sshstudio.tests.\(UUID().uuidString)"
        let plistURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshstudio-preview-\(UUID().uuidString).plist")
        let payload: NSDictionary = ["saved_sessions": Data("[]".utf8)]
        #expect(payload.write(to: plistURL, atomically: true))

        let defaults = SSHStudioDefaults.makeSharedDefaults(environment: [
            SSHStudioDefaults.suiteOverrideEnvironmentKey: suiteName,
            SSHStudioDefaults.plistOverrideEnvironmentKey: plistURL.path
        ])

        #expect(defaults.data(forKey: "saved_sessions") == Data("[]".utf8))
        try? FileManager.default.removeItem(at: plistURL)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func phase3ProfileMetadataRoundTrips() throws {
        let session = Session(
            name: "Research Cluster",
            host: "example.com",
            username: "researcher",
            favorite: true,
            group: "Research"
        )

        let data = try SessionPersistenceMigrator.encode([session])
        let result = try SessionPersistenceMigrator.decode(data)

        #expect(result.needsWrite == false)
        #expect(result.sessions.first?.favorite == true)
        #expect(result.sessions.first?.group == "Research")
        #expect(result.sessions.first?.schemaVersion == PersistedSessionProfile.currentSchemaVersion)
    }

    @Test func schemaOneProfilesMigrateToPhase3Schema() throws {
        let legacyProfile = PersistedSessionProfile(
            session: Session(name: "Analysis Server", host: "example.com", username: "analyst"),
            schemaVersion: 1
        )
        let data = try JSONEncoder().encode([legacyProfile])

        let result = try SessionPersistenceMigrator.decode(data)

        #expect(result.needsWrite == true)
        #expect(result.sessions.count == 1)
        #expect(result.sessions[0].favorite == false)
        #expect(result.sessions[0].group == "")
        #expect(result.sessions[0].schemaVersion == PersistedSessionProfile.currentSchemaVersion)
    }

    @Test func appShellCommandNotificationsAreStable() {
        #expect(Notification.Name.showSSHStudioNewConnection.rawValue == "showSSHStudioNewConnection")
        #expect(Notification.Name.toggleSSHStudioInspector.rawValue == "toggleSSHStudioInspector")
        #expect(Notification.Name.reconnectSSHStudioActiveSession.rawValue == "reconnectSSHStudioActiveSession")
        #expect(Notification.Name.closeSSHStudioActiveTab.rawValue == "closeSSHStudioActiveTab")
    }

    @Test func inspectorDefaultsHiddenForTerminalSpace() {
        let suite = "sshstudio-inspector-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.object(forKey: "app_shell_inspector_visible") == nil)
        #expect(defaults.bool(forKey: "app_shell_inspector_visible") == false)
    }
}
