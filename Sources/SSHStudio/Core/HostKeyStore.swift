import Foundation

protocol HostKeyStore: Sendable {
    func lookup(endpoint: SSHHostEndpoint) async throws -> [SSHHostKeyRecord]
    func addApprovedKey(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord
    func removeManagedKey(id: UUID) async throws
    func listRecords() async throws -> [SSHHostKeyRecord]
    func detectChangedKey(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord?
}

actor InMemoryHostKeyStore: HostKeyStore {
    private var records: [SSHHostKeyRecord]

    init(records: [SSHHostKeyRecord] = []) {
        self.records = records
    }

    func lookup(endpoint: SSHHostEndpoint) async throws -> [SSHHostKeyRecord] {
        records.filter { $0.endpoint.key == endpoint.key }
    }

    func addApprovedKey(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord {
        if let changed = try await detectChangedKey(candidate) {
            throw SSHHostKeyError.store("Existing trust record differs from \(changed.fingerprint.sha256).")
        }
        if let existing = records.first(where: {
            $0.endpoint.key == candidate.endpoint.key &&
            $0.algorithm == candidate.algorithm &&
            $0.fingerprint == candidate.fingerprint
        }) {
            return existing
        }
        let record = SSHHostKeyRecord(candidate: candidate, source: .sshStudio)
        records.append(record)
        return record
    }

    func removeManagedKey(id: UUID) async throws {
        guard let record = records.first(where: { $0.id == id }) else {
            throw SSHHostKeyError.notFound
        }
        guard record.source == .sshStudio else {
            throw SSHHostKeyError.store("System known-host entries cannot be removed by SSH Studio.")
        }
        records.removeAll { $0.id == id }
    }

    func listRecords() async throws -> [SSHHostKeyRecord] {
        records
    }

    func detectChangedKey(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord? {
        records.first {
            $0.endpoint.key == candidate.endpoint.key &&
            $0.algorithm == candidate.algorithm &&
            $0.fingerprint != candidate.fingerprint
        }
    }
}

struct SystemKnownHostsInspector: Sendable {
    var knownHostsFiles: [URL]

    init(knownHostsFiles: [URL]? = nil) {
        if let knownHostsFiles {
            self.knownHostsFiles = knownHostsFiles
        } else {
            let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh", isDirectory: true)
            self.knownHostsFiles = [
                sshDir.appendingPathComponent("known_hosts"),
                sshDir.appendingPathComponent("known_hosts2")
            ]
        }
    }

    func lookup(endpoint: SSHHostEndpoint) async -> Bool {
        for file in knownHostsFiles where FileManager.default.fileExists(atPath: file.path) {
            if await sshKeygenFind(endpoint: endpoint, file: file) {
                return true
            }
        }
        return false
    }

    private func sshKeygenFind(endpoint: SSHHostEndpoint, file: URL) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-F", endpoint.knownHostsName, "-f", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

actor ManagedHostKeyStore: HostKeyStore {
    private struct Payload: Codable {
        var version: Int = 1
        var records: [SSHHostKeyRecord] = []
    }

    private let fileURL: URL
    private let systemInspector: SystemKnownHostsInspector
    private let fileManager: FileManager

    init(
        fileURL: URL? = nil,
        systemInspector: SystemKnownHostsInspector = SystemKnownHostsInspector(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL ?? Self.defaultStoreURL(fileManager: fileManager)
        self.systemInspector = systemInspector
        self.fileManager = fileManager
    }

    static func defaultStoreURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("SSH Studio", isDirectory: true)
            .appendingPathComponent("HostKeys", isDirectory: true)
            .appendingPathComponent("managed_known_hosts.json")
    }

    func lookup(endpoint: SSHHostEndpoint) async throws -> [SSHHostKeyRecord] {
        var records = try load().records.filter { $0.endpoint.key == endpoint.key }
        if await systemInspector.lookup(endpoint: endpoint) {
            records.append(SSHHostKeyRecord(
                endpoint: endpoint,
                algorithm: .unknown,
                publicKey: "",
                fingerprint: SSHHostFingerprint(sha256: "system-known-hosts"),
                source: .system,
                dateAdded: nil,
                profileIDs: endpoint.profileID.map { [$0] } ?? []
            ))
        }
        return records
    }

    func addApprovedKey(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord {
        var payload = try load()
        if let changed = payload.records.first(where: {
            $0.endpoint.key == candidate.endpoint.key &&
            $0.algorithm == candidate.algorithm &&
            $0.fingerprint != candidate.fingerprint
        }) {
            throw SSHHostKeyError.store("Existing SSH Studio trust record differs from \(changed.fingerprint.sha256).")
        }
        if let existing = payload.records.first(where: {
            $0.endpoint.key == candidate.endpoint.key &&
            $0.algorithm == candidate.algorithm &&
            $0.fingerprint == candidate.fingerprint
        }) {
            return existing
        }
        let record = SSHHostKeyRecord(candidate: candidate, source: .sshStudio)
        payload.records.append(record)
        try save(payload)
        return record
    }

    func removeManagedKey(id: UUID) async throws {
        var payload = try load()
        guard let record = payload.records.first(where: { $0.id == id }) else {
            throw SSHHostKeyError.notFound
        }
        guard record.source == .sshStudio else {
            throw SSHHostKeyError.store("System known-host entries cannot be removed by SSH Studio.")
        }
        payload.records.removeAll { $0.id == id }
        try save(payload)
    }

    func listRecords() async throws -> [SSHHostKeyRecord] {
        try load().records
    }

    func detectChangedKey(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord? {
        try load().records.first {
            $0.endpoint.key == candidate.endpoint.key &&
            $0.algorithm == candidate.algorithm &&
            $0.fingerprint != candidate.fingerprint
        }
    }

    private func load() throws -> Payload {
        guard fileManager.fileExists(atPath: fileURL.path) else { return Payload() }
        let data = try Data(contentsOf: fileURL)
        guard data.count < 2_000_000 else { throw SSHHostKeyError.oversizedOutput }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    private func save(_ payload: Payload) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
