import CryptoKit
import Foundation

enum SSHSecurity {
    static let baseOptions = SSHCommandBuilder.baseOptions

    static func destinationArgs(for session: Session) -> [String] {
        SSHCommandBuilder.destinationArgs(for: session)
    }

    static func rsyncSSHArgs(for session: Session, qos: String = "throughput") -> [String] {
        SSHCommandBuilder.rsyncSSHArgs(for: session, qos: qos)
    }

    static func validateNonInteractive(session: Session, purpose: String) throws {
        try SSHCommandBuilder.validate(session: session, allowPassword: false, purposeLabel: purpose)
    }

    static func rsyncTarget(for session: Session) -> String {
        connectionTarget(for: session)
    }

    static func connectionTarget(for session: Session) -> String {
        SSHCommandBuilder.connectionTarget(for: session)
    }

    static func controlPath(for session: Session) -> String {
        let identity = [
            session.id.uuidString,
            session.sshConfigAlias,
            session.username,
            session.host,
            "\(session.port)",
            "\(session.authentication.kind)",
            session.privateKeyPath,
            session.credentialReferenceID
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = controlSocketDirectory()
        return directory.appendingPathComponent("ssh-studio-\(digest).sock").path
    }

    static func controlSocketDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent("SSH Studio/ControlSockets", isDirectory: true)
        if openSSHOptionSafePath(directory.path), secureDirectory(directory) {
            return directory
        }
        let runtime = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ssh-studio-\(sanitizedRuntimeComponent(NSUserName()))/ControlSockets", isDirectory: true)
        _ = secureDirectory(runtime)
        return runtime
    }

    private static func openSSHOptionSafePath(_ path: String) -> Bool {
        !path.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20
        }
    }

    private static func sanitizedRuntimeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars)
        return sanitized.isEmpty ? "user" : sanitized
    }

    @discardableResult
    private static func secureDirectory(_ directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return false
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            return permissions & 0o077 == 0
        } catch {
            return false
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func remoteShellPath(_ path: String) -> String {
        if path == "~" { return path }
        if path.hasPrefix("~/") {
            return "~/" + shellQuote(String(path.dropFirst(2)))
        }
        return shellQuote(path)
    }

    static func validate(session: Session) throws {
        try SSHCommandBuilder.validate(session: session)
    }

    static func validateTunnel(_ tunnel: TunnelConfig) throws {
        try SSHCommandBuilder.validate(tunnel: tunnel)
    }
}

enum SSHSecurityError: LocalizedError {
    case invalidSession(String)

    var errorDescription: String? {
        switch self {
        case .invalidSession(let message): return message
        }
    }
}
