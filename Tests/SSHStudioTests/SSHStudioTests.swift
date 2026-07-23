import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Security Foundation")
struct SSHStudioSecurityTests {
    @Test func sessionCodableRoundTrip() throws {
        let id = UUID()
        let session = Session(
            id: id,
            name: "Lab",
            host: "example.internal",
            port: 2222,
            username: "labuser",
            authMethod: .privateKey,
            privateKeyPath: "/Users/example/.ssh/id_ed25519",
            sshConfigAlias: "lab-alias",
            credentialReferenceID: "credential-reference",
            remoteDirectory: "~/work"
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.schemaVersion == Session.currentSchemaVersion)
        #expect(decoded.privateKeyPath == session.privateKeyPath)
        #expect(decoded.sshConfigAlias == session.sshConfigAlias)
        #expect(decoded.credentialReferenceID == session.credentialReferenceID)
    }

    @Test func legacySavedSessionsMigrationIsLosslessAndIdempotent() throws {
        let legacyJSON = """
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy Lab",
          "host": "legacy.example",
          "port": 22,
          "username": "legacyuser",
          "authMethod": "Private Key",
          "privateKeyPath": "/Users/example/.ssh/id_legacy",
          "sshConfigAlias": "legacy-alias",
          "remoteDirectory": "~/legacy",
          "screenSharingHost": "",
          "screenSharingPort": 5900,
          "remoteScreenMode": "SSH Tunnel",
          "remoteAccessAddress": "",
          "tunnels": []
        }]
        """
        let legacyData = Data(legacyJSON.utf8)

        let migrated = try SessionPersistenceMigrator.decode(legacyData)
        #expect(migrated.needsWrite)
        #expect(migrated.sessions.count == 1)
        #expect(migrated.sessions[0].id.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(migrated.sessions[0].privateKeyPath == "/Users/example/.ssh/id_legacy")
        #expect(migrated.sessions[0].sshConfigAlias == "legacy-alias")

        let encoded = try SessionPersistenceMigrator.encode(migrated.sessions)
        let decodedAgain = try SessionPersistenceMigrator.decode(encoded)
        #expect(!decodedAgain.needsWrite)
        #expect(decodedAgain.sessions == migrated.sessions)
    }

    @Test func hostnameValidation() {
        var session = sampleSession()
        #expect(throws: Never.self) {
            try SSHCommandBuilder.validate(session: session)
        }
        session.host = "bad host;rm"
        #expect(throws: (any Error).self) {
            try SSHCommandBuilder.validate(session: session)
        }
    }

    @Test func portValidation() {
        var session = sampleSession()
        session.port = 0
        #expect(throws: (any Error).self) {
            try SSHCommandBuilder.validate(session: session)
        }
        session.port = 65536
        #expect(throws: (any Error).self) {
            try SSHCommandBuilder.validate(session: session)
        }
    }

    @Test func usernameValidation() {
        var session = sampleSession()
        session.username = "bad user"
        #expect(throws: (any Error).self) {
            try SSHCommandBuilder.validate(session: session)
        }
    }

    @Test func remotePathEscaping() {
        #expect(SSHSecurity.remoteShellPath("~") == "~")
        #expect(SSHSecurity.remoteShellPath("/tmp/a b") == "'/tmp/a b'")
        #expect(SSHSecurity.remoteShellPath("~/a b") == "~/'a b'")
        #expect(SSHSecurity.remoteShellPath("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    @Test func tunnelArgumentGeneration() throws {
        var tunnel = TunnelConfig()
        tunnel.name = "Web"
        tunnel.type = .local
        tunnel.listenHost = "127.0.0.1"
        tunnel.localPort = 8080
        tunnel.remoteHost = "localhost"
        tunnel.remotePort = 80

        let invocation = try SSHCommandBuilder.tunnelInvocation(for: tunnel, session: sampleKeySession())
        #expect(invocation.executableURL.path == "/usr/bin/ssh")
        #expect(invocation.arguments.contains("-N"))
        #expect(invocation.arguments.contains("-L"))
        #expect(invocation.arguments.contains("127.0.0.1:8080:localhost:80"))
        #expect(invocation.arguments.contains("HashKnownHosts=yes"))
        #expect(!invocation.arguments.contains("StrictHostKeyChecking=no"))
    }

    @Test func redactionRemovesSensitiveValues() {
        let passwordSample = ["pw", "sample"].joined(separator: "-")
        let passphraseSample = ["phrase", "sample"].joined(separator: "-")
        let tokenSample = ["token", "sample"].joined(separator: "-")
        let sensitive = [
            "labuser",
            "secret.example",
            "/Users/example/.ssh/id_secret",
            passwordSample,
            passphraseSample,
            tokenSample,
            "~/sensitive/project"
        ]
        let input = [
            "labuser@secret.example",
            "-i /Users/example/.ssh/id_secret",
            ["pass", "word"].joined() + "=\(passwordSample)",
            ["pass", "phrase"].joined() + "=\(passphraseSample)",
            ["tok", "en"].joined() + "=\(tokenSample)",
            "path=~/sensitive/project"
        ].joined(separator: " ")
        let output = DiagnosticRedactor.redact(input, sensitiveValues: sensitive)

        for value in sensitive {
            #expect(!output.contains(value))
        }
    }

    @Test func invocationRedactedDescriptionDoesNotExposeSensitiveValues() throws {
        let session = sampleKeySession()
        let invocation = try SSHCommandBuilder.terminalInvocation(for: session)
        #expect(!invocation.redactedDescription.contains(session.username))
        #expect(!invocation.redactedDescription.contains(session.host))
        #expect(!invocation.redactedDescription.contains(session.privateKeyPath))
    }

    @Test func duplicateSessionIdentityBehavior() {
        let session = sampleSession()
        let duplicateID = OpenSessionSelection.existingSessionID(for: session, in: [session])
        #expect(duplicateID == session.id)
    }

    private func sampleSession() -> Session {
        Session(name: "Sample", host: "example.internal", username: "labuser")
    }

    private func sampleKeySession() -> Session {
        Session(
            name: "Sample",
            host: "secret.example",
            username: "labuser",
            authMethod: .privateKey,
            privateKeyPath: "/Users/example/.ssh/id_secret"
        )
    }
}

@Suite("SSH Studio Connection Foundation")
@MainActor
struct SSHStudioConnectionTests {
    @Test func processExitChangesVisibleState() {
        let service = SSHConnectionService()
        service.prepare()
        service.processStarted()
        #expect(service.state.displayLabel == "Connected")

        service.processTerminated(exitStatus: 255, message: "Connection closed")
        #expect(service.state.displayLabel == "Failed")
    }

    @Test func reconnectCanBeCancelled() {
        let service = SSHConnectionService()
        service.scheduleReconnect(policy: SSHReconnectPolicy(maxAttempts: 3, initialDelay: 10, maxDelay: 10)) {}
        #expect(service.state.displayLabel == "Reconnecting")
        service.cancelReconnect()
        #expect(service.state.displayLabel == "Disconnected")
    }

    @Test func reconnectPolicyUsesBoundedExponentialBackoff() {
        let policy = SSHReconnectPolicy(maxAttempts: 5, initialDelay: 1, maxDelay: 5)
        #expect(policy.delay(forAttempt: 1) == 1)
        #expect(policy.delay(forAttempt: 2) == 2)
        #expect(policy.delay(forAttempt: 4) == 5)
    }

    @Test func inMemoryCredentialStoreCRUD() throws {
        let store = InMemoryCredentialStore()
        let reference = try store.create(CredentialSecret(string: "value"), label: "Test")
        #expect(try store.read(reference).dataValue() == Data("value".utf8))

        try store.update(reference, secret: CredentialSecret(string: "updated"))
        #expect(try store.read(reference).dataValue() == Data("updated".utf8))

        try store.delete(reference)
        #expect(throws: (any Error).self) {
            try store.read(reference)
        }
    }
}
