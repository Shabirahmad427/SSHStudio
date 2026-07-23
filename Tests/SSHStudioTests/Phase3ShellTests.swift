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
        let defaults = SSHStudioDefaults.makeSharedDefaults(environment: [:])
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
}
