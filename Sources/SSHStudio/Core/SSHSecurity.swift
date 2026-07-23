import CryptoKit
import Foundation

enum SSHSecurity {
    static let baseOptions = [
        "-o", "ConnectTimeout=10",
        "-o", "ForwardAgent=no",
        "-o", "HashKnownHosts=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "TCPKeepAlive=yes"
    ]

    static func destinationArgs(for session: Session) -> [String] {
        var args: [String] = []
        if session.authMethod == .privateKey && !session.privateKeyPath.isEmpty {
            args += ["-o", "IdentitiesOnly=yes", "-i", session.privateKeyPath]
        }
        return args + ["-p", "\(session.port)", "--", connectionTarget(for: session)]
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
        try validate(session: session)
        if session.authMethod == .password {
            throw SSHSecurityError.invalidSession(
                "\(purpose) requires key-based authentication or an SSH config alias that does not need an interactive password. The Terminal tab can still prompt for passwords."
            )
        }
    }

    static func rsyncTarget(for session: Session) -> String {
        connectionTarget(for: session)
    }

    static func connectionTarget(for session: Session) -> String {
        let host: String
        if session.sshConfigAlias.isEmpty {
            host = session.host.contains(":") && !session.host.hasPrefix("[")
                ? "[\(session.host)]"
                : session.host
        } else {
            host = session.sshConfigAlias
        }
        return "\(session.username)@\(host)"
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
        guard (1...65535).contains(session.port) else {
            throw SSHSecurityError.invalidSession("SSH port must be between 1 and 65535.")
        }
        if session.sshConfigAlias.isEmpty {
            guard matches(session.host, pattern: "^[A-Za-z0-9._:\\[\\]-]+$"),
                  matches(session.username, pattern: "^[A-Za-z0-9._-]+$") else {
                throw SSHSecurityError.invalidSession("SSH host and username contain unsupported characters.")
            }
        } else {
            guard matches(session.sshConfigAlias, pattern: "^[A-Za-z0-9._-]+$") else {
                throw SSHSecurityError.invalidSession("SSH config alias contains unsupported characters.")
            }
        }
    }

    static func validateTunnel(_ tunnel: TunnelConfig) throws {
        guard isSafeForwardingHost(tunnel.listenHost),
              isSafeForwardingHost(tunnel.remoteHost),
              (1...65535).contains(tunnel.localPort),
              (1...65535).contains(tunnel.remotePort) else {
            throw SSHSecurityError.invalidSession("Tunnel hosts or ports are invalid.")
        }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isSafeForwardingHost(_ value: String) -> Bool {
        !value.isEmpty &&
            value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\r\n,:")) == nil
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
