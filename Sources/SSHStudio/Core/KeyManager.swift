import Foundation

struct SSHKey: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var publicKeyPath: String
    var privateKeyPath: String
    var keyType: KeyType
    var comment: String
    var createdAt: Date

    enum KeyType: String, Codable, CaseIterable {
        case ed25519 = "Ed25519"
        case rsa4096 = "RSA 4096"
        case rsa2048 = "RSA 2048"
        case ecdsa   = "ECDSA"
    }
}

@MainActor
class KeyManager: ObservableObject {
    static let shared = KeyManager()
    @Published var keys: [SSHKey] = []

    private let storageKey = "ssh_keys"
    private let defaults = SSHStudioDefaults.shared

    init() { load() }

    func generateKey(name: String, type: SSHKey.KeyType, comment: String,
                     passphrase: String, completion: @escaping @MainActor (Result<SSHKey, Error>) -> Void) {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        let safeName = name.replacingOccurrences(of: " ", with: "_")
        guard safeName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              safeName != ".", safeName != ".." else {
            completion(.failure(KeyManagerError.invalidName))
            return
        }
        let keyPath = dir.appendingPathComponent(safeName).path
        guard !FileManager.default.fileExists(atPath: keyPath),
              !FileManager.default.fileExists(atPath: keyPath + ".pub") else {
            completion(.failure(KeyManagerError.alreadyExists))
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            completion(.failure(error))
            return
        }

        var args: [String]
        switch type {
        case .ed25519: args = ["-t", "ed25519"]
        case .rsa4096: args = ["-t", "rsa", "-b", "4096"]
        case .rsa2048: args = ["-t", "rsa", "-b", "2048"]
        case .ecdsa:   args = ["-t", "ecdsa", "-b", "521"]
        }
        args += ["-C", comment, "-f", keyPath]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = args

        let pipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = inputPipe

        process.terminationHandler = { @Sendable p in
            let status = p.terminationStatus
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            Task { @MainActor in
                if status == 0 {
                    let key = SSHKey(
                        id: UUID(), name: name,
                        publicKeyPath: keyPath + ".pub",
                        privateKeyPath: keyPath,
                        keyType: type, comment: comment,
                        createdAt: Date()
                    )
                    self.keys.append(key)
                    self.save()
                    ConnectionLog.shared.log("Generated \(type.rawValue) key: \(name)", level: .success)
                    completion(.success(key))
                } else {
                    completion(.failure(NSError(domain: msg, code: 1)))
                }
            }
        }
        do {
            try process.run()
            if let data = "\(passphrase)\n\(passphrase)\n".data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
        } catch {
            completion(.failure(error))
        }
    }

    func delete(_ key: SSHKey) {
        try? FileManager.default.removeItem(atPath: key.privateKeyPath)
        try? FileManager.default.removeItem(atPath: key.publicKeyPath)
        keys.removeAll { $0.id == key.id }
        save()
    }

    func publicKeyContent(_ key: SSHKey) -> String? {
        try? String(contentsOfFile: key.publicKeyPath, encoding: .utf8)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(keys) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SSHKey].self, from: data) {
            keys = decoded
        }
    }
}

private enum KeyManagerError: LocalizedError {
    case invalidName
    case alreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Key names may contain only letters, numbers, periods, underscores, hyphens, and spaces."
        case .alreadyExists:
            return "A key with this name already exists in ~/.ssh."
        }
    }
}
