import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 5 Authentication")
struct Phase5AuthenticationTests {
    @Test func schemaThreeProfilesMigrateToTypedAuthentication() throws {
        var session = Session(
            name: "Legacy Key",
            host: "example.com",
            username: "user",
            authMethod: .privateKey,
            privateKeyPath: "/tmp/key"
        )
        session.schemaVersion = 3
        let profile = PersistedSessionProfile(session: session, schemaVersion: 3)
        let data = try JSONEncoder().encode([profile])

        let result = try SessionPersistenceMigrator.decode(data)

        #expect(result.needsWrite == true)
        #expect(result.sessions[0].schemaVersion == PersistedSessionProfile.currentSchemaVersion)
        #expect(result.sessions[0].authentication.privateKeyPath == "/tmp/key")
    }

    @Test func authenticationMethodsRoundTripWithoutSecrets() throws {
        let methods: [ProfileAuthenticationMethod] = [
            .privateKey(path: "/tmp/key", useAgent: true, addKeysToAgent: true, useKeychain: true),
            .sshAgent,
            .macOSKeychain(path: "/tmp/key", addKeysToAgent: true),
            .passwordCredential(referenceID: UUID().uuidString),
            .sshConfigManaged
        ]

        let data = try JSONEncoder().encode(methods)
        let decoded = try JSONDecoder().decode([ProfileAuthenticationMethod].self, from: data)

        #expect(decoded == methods)
        #expect(!String(decoding: data, as: UTF8.self).contains("secret"))
    }

    @Test func commandBuilderAddsMacOSKeychainOptionsSafely() throws {
        let session = Session(
            name: "Keychain",
            host: "example.com",
            username: "user",
            authMethod: .privateKey,
            authentication: .macOSKeychain(path: "/tmp/key", addKeysToAgent: true),
            privateKeyPath: "/tmp/key"
        )

        let invocation = try SSHCommandBuilder.terminalInvocation(for: session)

        #expect(invocation.arguments.contains("IgnoreUnknown=UseKeychain"))
        #expect(invocation.arguments.contains("UseKeychain=yes"))
        #expect(invocation.arguments.contains("AddKeysToAgent=yes"))
    }

    @Test func passwordCredentialInvocationUsesPackagedAskPassEnvironment() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("sshstudio-askpass-\(UUID().uuidString)", isDirectory: true)
        let bundle = temporary.appendingPathComponent("SSH Studio.app", isDirectory: true)
        let helper = AskPassSupport.helperURL(in: bundle)
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let reference = UUID().uuidString
        let environment = try AskPassSupport.environment(
            credentialReferenceID: reference,
            appBundleURL: bundle
        )

        #expect(environment["SSH_ASKPASS"] == helper.path)
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment[AskPassSupport.credentialReferenceEnvironmentKey] == reference)
    }

    @Test func credentialReferenceLifecycleAndDuplicationAvoidSecretCopy() throws {
        let store = InMemoryCredentialStore()
        let reference = try store.create(CredentialSecret(string: "sample"), label: "Fixture")
        #expect(store.exists(reference))

        var session = Session(
            name: "Credential",
            host: "example.com",
            username: "user",
            authentication: .passwordCredential(referenceID: reference.id),
            credentialReferenceID: reference.id
        )
        let duplicate = CredentialLifecycle.duplicateProfileWithoutSecret(session)
        #expect(duplicate.credentialReferenceID == "")
        #expect(duplicate.authentication.credentialReferenceID == nil)

        session.credentialReferenceID = "missing"
        session.authentication = .passwordCredential(referenceID: "missing")
        #expect(CredentialLifecycle.orphanedReferences(sessions: [session], store: store).map(\.id) == ["missing"])

        try store.delete(reference)
        #expect(!store.exists(reference))
    }
}
