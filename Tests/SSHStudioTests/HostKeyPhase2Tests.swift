import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Host Key Phase 2")
struct HostKeyPhase2Tests {
    @Test func standardAndNonstandardKnownHostNotation() {
        #expect(SSHHostEndpoint(hostname: "example.internal", port: 22).knownHostsName == "example.internal")
        #expect(SSHHostEndpoint(hostname: "example.internal", port: 2222).knownHostsName == "[example.internal]:2222")
        #expect(SSHHostEndpoint(hostname: "2001:db8::1", port: 2200).knownHostsName == "[2001:db8::1]:2200")
    }

    @Test func endpointIdentityUsesPortAndProfile() {
        let profileID = UUID()
        let a = SSHHostEndpoint(hostname: "host", port: 22, profileID: profileID)
        let b = SSHHostEndpoint(hostname: "host", port: 2222, profileID: profileID)
        #expect(a.key != b.key)
    }

    @Test func matchingSSHStudioKeyIsTrusted() async {
        let endpoint = SSHHostEndpoint(hostname: "example.internal")
        let candidate = try! candidate(endpoint: endpoint, keySeed: "one")
        let record = SSHHostKeyRecord(candidate: candidate, source: .sshStudio)
        let service = HostKeyVerificationService(
            store: InMemoryHostKeyStore(records: [record]),
            discovery: FakeHostKeyDiscovery(candidates: [candidate])
        )

        let state = await service.evaluate(endpoint: endpoint)
        #expect(state == .trustedBySSHStudio)
    }

    @Test func matchingSystemKeyIsTrustedWithoutScanning() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshstudio-system-known-hosts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let knownHosts = directory.appendingPathComponent("known_hosts")
        let publicKey = Data("system-key".utf8).base64EncodedString()
        try "system.internal ssh-ed25519 \(publicKey)\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        let endpoint = SSHHostEndpoint(hostname: "system.internal")
        let store = ManagedHostKeyStore(
            fileURL: directory.appendingPathComponent("managed.json"),
            systemInspector: SystemKnownHostsInspector(knownHostsFiles: [knownHosts])
        )
        let discovery = FakeHostKeyDiscovery(error: SSHHostKeyError.store("scan should not run"))
        let service = HostKeyVerificationService(store: store, discovery: discovery)

        let state = await service.evaluate(endpoint: endpoint)
        #expect(state == .trustedBySystem)
        #expect(await discovery.callCount == 0)
    }

    @Test func unknownHostReturnsUnverifiedCandidates() async {
        let endpoint = SSHHostEndpoint(hostname: "unknown.internal")
        let candidate = try! candidate(endpoint: endpoint, keySeed: "one")
        let service = HostKeyVerificationService(
            store: InMemoryHostKeyStore(),
            discovery: FakeHostKeyDiscovery(candidates: [candidate])
        )

        let state = await service.evaluate(endpoint: endpoint)
        guard case .unknown(let candidates) = state else {
            Issue.record("Expected unknown state")
            return
        }
        #expect(candidates == [candidate])
    }

    @Test func changedKeyIsBlocked() async {
        let endpoint = SSHHostEndpoint(hostname: "changed.internal")
        let old = try! candidate(endpoint: endpoint, keySeed: "old")
        let new = try! candidate(endpoint: endpoint, keySeed: "new")
        let service = HostKeyVerificationService(
            store: InMemoryHostKeyStore(records: [SSHHostKeyRecord(candidate: old, source: .sshStudio)]),
            discovery: FakeHostKeyDiscovery(candidates: [new])
        )

        let state = await service.evaluate(endpoint: endpoint)
        guard case .changed(let previous, let presented) = state else {
            Issue.record("Expected changed state")
            return
        }
        #expect(previous.fingerprint == old.fingerprint)
        #expect(presented.fingerprint == new.fingerprint)
    }

    @Test func multipleAlgorithmsArePreserved() async throws {
        let endpoint = SSHHostEndpoint(hostname: "multi.internal")
        let ed25519 = try candidate(endpoint: endpoint, algorithm: .ed25519, keySeed: "one")
        let rsa = try candidate(endpoint: endpoint, algorithm: .rsa, keySeed: "two")
        let store = InMemoryHostKeyStore()
        _ = try await store.addApprovedKey(ed25519)
        _ = try await store.addApprovedKey(rsa)
        let records = try await store.lookup(endpoint: endpoint)
        #expect(records.count == 2)
    }

    @Test func malformedAndOversizedScanOutputIsRejected() {
        let endpoint = SSHHostEndpoint(hostname: "bad.internal")
        #expect(throws: (any Error).self) {
            try SSHKeyscanProcessAdapter.parseScanOutput(Data("bad line".utf8), endpoint: endpoint)
        }
        #expect(throws: (any Error).self) {
            try SSHKeyscanProcessAdapter.parseScanOutput(Data(repeating: 65, count: 70_000), endpoint: endpoint)
        }
    }

    @Test func scanTimeoutAndCancellationAreReported() async {
        let endpoint = SSHHostEndpoint(hostname: "timeout.internal")
        let timeoutService = HostKeyVerificationService(
            store: InMemoryHostKeyStore(),
            discovery: FakeHostKeyDiscovery(error: SSHHostKeyError.timeout)
        )
        let timeoutState = await timeoutService.evaluate(endpoint: endpoint)
        guard case .failed(let timeoutMessage) = timeoutState else {
            Issue.record("Expected timeout failure")
            return
        }
        #expect(timeoutMessage.contains("timed out"))

        let cancelService = HostKeyVerificationService(
            store: InMemoryHostKeyStore(),
            discovery: FakeHostKeyDiscovery(error: SSHHostKeyError.cancelled)
        )
        let cancelState = await cancelService.evaluate(endpoint: endpoint)
        guard case .failed(let cancelMessage) = cancelState else {
            Issue.record("Expected cancellation failure")
            return
        }
        #expect(cancelMessage.contains("cancelled"))
    }

    @Test func scanOutputParsesFingerprint() throws {
        let endpoint = SSHHostEndpoint(hostname: "scan.internal")
        let publicKey = Data("scan-key".utf8).base64EncodedString()
        let line = "scan.internal ssh-ed25519 \(publicKey)\n"
        let candidates = try SSHKeyscanProcessAdapter.parseScanOutput(Data(line.utf8), endpoint: endpoint)
        #expect(candidates.count == 1)
        #expect(candidates[0].fingerprint.sha256.hasPrefix("SHA256:"))
    }

    @Test func atomicManagedStoreWritesAndRemovesManagedOnly() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sshstudio-hostkey-tests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("managed_known_hosts.json")
        let endpoint = SSHHostEndpoint(hostname: "store.internal")
        let store = ManagedHostKeyStore(fileURL: file, systemInspector: SystemKnownHostsInspector(knownHostsFiles: []))
        let record = try await store.addApprovedKey(candidate(endpoint: endpoint, keySeed: "one"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try await store.removeManagedKey(id: record.id)
        #expect(try await store.listRecords().isEmpty)
    }

    @Test func concurrentTrustRequestsCoalesce() async {
        let endpoint = SSHHostEndpoint(hostname: "concurrent.internal")
        let discovery = FakeHostKeyDiscovery(candidates: [try! candidate(endpoint: endpoint, keySeed: "one")], delayNanoseconds: 5_000_000)
        let service = HostKeyVerificationService(store: InMemoryHostKeyStore(), discovery: discovery)
        async let a = service.evaluate(endpoint: endpoint)
        async let b = service.evaluate(endpoint: endpoint)
        _ = await (a, b)
        #expect(await discovery.callCount == 1)
    }

    @Test func trustApprovalAndReplacementPrevention() async throws {
        let endpoint = SSHHostEndpoint(hostname: "approval.internal")
        let first = try candidate(endpoint: endpoint, keySeed: "one")
        let second = try candidate(endpoint: endpoint, keySeed: "two")
        let service = HostKeyVerificationService(store: InMemoryHostKeyStore(), discovery: FakeHostKeyDiscovery(candidates: [first]))
        _ = try await service.approve(first)
        await service.reject(endpoint: endpoint)
        await #expect(throws: (any Error).self) {
            try await service.approve(second)
        }
    }

    @Test func invocationPoliciesForAllPurposes() throws {
        let session = Session(
            name: "Policy",
            host: "policy.internal",
            username: "policyuser",
            authMethod: .privateKey,
            privateKeyPath: "/Users/example/.ssh/id_policy"
        )
        var tunnel = TunnelConfig()
        tunnel.remoteHost = "localhost"

        let terminal = try SSHCommandBuilder.terminalInvocation(for: session)
        let tunnelInvocation = try SSHCommandBuilder.tunnelInvocation(for: tunnel, session: session)
        let sftp = try SSHCommandBuilder.sftpInvocation(for: session)
        let remote = try SSHCommandBuilder.remoteCommandInvocation(for: session, command: "true", purpose: .sync)
        let screen = try SSHCommandBuilder.screenSharingTunnelInvocation(session: session, displayHost: "localhost", localPort: 5901)
        let rsyncArgs = SSHCommandBuilder.rsyncSSHArgs(for: session)

        for invocation in [terminal, tunnelInvocation, sftp, remote, screen] {
            #expect(invocation.arguments.contains("HashKnownHosts=yes"))
            #expect(!invocation.arguments.contains("StrictHostKeyChecking=no"))
            #expect(invocation.hostKeyPolicy == .openSSHDefault)
        }
        #expect(rsyncArgs.contains("HashKnownHosts=yes"))
        #expect(!rsyncArgs.contains("StrictHostKeyChecking=no"))
    }

    private func candidate(
        endpoint: SSHHostEndpoint,
        algorithm: SSHHostKeyAlgorithm = .ed25519,
        keySeed: String
    ) throws -> SSHHostKeyCandidate {
        let publicKey = Data("public-\(keySeed)".utf8).base64EncodedString()
        return SSHHostKeyCandidate(
            endpoint: endpoint,
            algorithm: algorithm,
            publicKey: publicKey,
            fingerprint: try SSHHostFingerprint.computeSHA256(publicKeyBase64: publicKey)
        )
    }
}

actor FakeHostKeyDiscovery: HostKeyDiscovery {
    private let candidates: [SSHHostKeyCandidate]
    private let error: Error?
    private let delayNanoseconds: UInt64
    private(set) var callCount = 0

    init(candidates: [SSHHostKeyCandidate] = [], error: Error? = nil, delayNanoseconds: UInt64 = 0) {
        self.candidates = candidates
        self.error = error
        self.delayNanoseconds = delayNanoseconds
    }

    func scan(endpoint: SSHHostEndpoint) async throws -> [SSHHostKeyCandidate] {
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
        return candidates
    }
}
