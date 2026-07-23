import CryptoKit
import Foundation

enum SSHSecurity {
    static let baseOptions = SSHCommandBuilder.baseOptions

    static func destinationArgs(for session: Session) -> [String] {
        SSHCommandBuilder.destinationArgs(for: session)
    }

    static func rsyncSSHArgs(for session: Session, qos: String = "throughput") -> [String] {
        var args = [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath(for: session))",
            "-o", "Compression=no",
            "-o", "IPQoS=\(qos)"
        ]
        args += baseOptions
        if session.authMethod == .privateKey && !session.privateKeyPath.isEmpty {
            args += ["-o", "IdentitiesOnly=yes", "-i", session.privateKeyPath]
        }
        args += ["-p", "\(session.port)"]
        return args
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
            session.sshConfigAlias,
            session.username,
            session.host,
            "\(session.port)"
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(NSHomeDirectory())/.ssh/ssh-studio-\(digest).sock"
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
