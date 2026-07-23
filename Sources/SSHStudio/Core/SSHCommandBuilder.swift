import Foundation

enum SSHPurpose: String, Codable, Equatable {
    case terminal
    case tunnel
    case sftp
    case sync
    case screenSharing
}

enum SSHHostKeyPolicy: String, Codable, Equatable {
    case openSSHDefault
}

enum SSHAuthenticationMethod: Equatable {
    case password
    case privateKey(path: String)

    static func from(session: Session) -> Self {
        if session.authMethod == .privateKey, !session.privateKeyPath.isEmpty {
            return .privateKey(path: session.privateKeyPath)
        }
        return .password
    }
}

enum SSHValidationError: LocalizedError, Equatable {
    case invalidHost
    case invalidUsername
    case invalidAlias
    case invalidPort
    case invalidForwardingSpecification
    case passwordNotAllowed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "SSH host contains unsupported characters."
        case .invalidUsername:
            return "SSH username contains unsupported characters."
        case .invalidAlias:
            return "SSH config alias contains unsupported characters."
        case .invalidPort:
            return "SSH port must be between 1 and 65535."
        case .invalidForwardingSpecification:
            return "Tunnel hosts or ports are invalid."
        case .passwordNotAllowed(let purpose):
            return "\(purpose) requires key-based authentication or an SSH config alias that does not need an interactive password. The Terminal tab can still prompt for passwords."
        }
    }
}

struct SSHInvocation: Equatable {
    let purpose: SSHPurpose
    let executableURL: URL
    let arguments: [String]
    let sensitiveValues: [String]

    var redactedArguments: [String] {
        DiagnosticRedactor.redactedArguments(arguments, sensitiveValues: sensitiveValues)
    }

    var redactedDescription: String {
        ([executableURL.path] + redactedArguments).joined(separator: " ")
    }
}

enum SSHCommandBuilder {
    static let sshExecutableURL = URL(fileURLWithPath: "/usr/bin/ssh")

    static let baseOptions = [
        "-o", "ConnectTimeout=10",
        "-o", "ForwardAgent=no",
        "-o", "HashKnownHosts=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "TCPKeepAlive=yes"
    ]

    static func terminalInvocation(for session: Session) throws -> SSHInvocation {
        try validate(session: session, allowPassword: true, purposeLabel: "Terminal")
        var args: [String] = []
        args += ["-o", "ControlMaster=no"]
        args += baseOptions
        args += ["-o", "IPQoS=lowdelay"]
        args += ["-o", "Compression=no"]
        args += ["-o", "RequestTTY=yes"]
        args += destinationArgs(for: session)
        return SSHInvocation(
            purpose: .terminal,
            executableURL: sshExecutableURL,
            arguments: args,
            sensitiveValues: sensitiveValues(for: session)
        )
    }

    static func tunnelInvocation(for tunnel: TunnelConfig, session: Session) throws -> SSHInvocation {
        try validate(session: session, allowPassword: false, purposeLabel: "SSH tunnels")
        try validate(tunnel: tunnel)

        var args: [String] = ["-N", "-o", "ExitOnForwardFailure=yes"]
        switch tunnel.type {
        case .local:
            args += ["-L", "\(tunnel.listenHost):\(tunnel.localPort):\(tunnel.remoteHost):\(tunnel.remotePort)"]
        case .remote:
            args += ["-R", "\(tunnel.listenHost):\(tunnel.remotePort):\(tunnel.remoteHost):\(tunnel.localPort)"]
        case .dynamic:
            args += ["-D", "\(tunnel.listenHost):\(tunnel.localPort)"]
        }
        args += baseOptions
        args += destinationArgs(for: session)
        return SSHInvocation(
            purpose: .tunnel,
            executableURL: sshExecutableURL,
            arguments: args,
            sensitiveValues: sensitiveValues(for: session)
        )
    }

    static func destinationArgs(for session: Session) -> [String] {
        var args: [String] = []
        if case .privateKey(let path) = SSHAuthenticationMethod.from(session: session) {
            args += ["-o", "IdentitiesOnly=yes", "-i", path]
        }
        return args + ["-p", "\(session.port)", "--", connectionTarget(for: session)]
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

    static func validate(session: Session, allowPassword: Bool = true, purposeLabel: String = "SSH") throws {
        guard (1...65535).contains(session.port) else {
            throw SSHValidationError.invalidPort
        }
        if session.sshConfigAlias.isEmpty {
            guard matches(session.host, pattern: "^[A-Za-z0-9._:\\[\\]-]+$") else {
                throw SSHValidationError.invalidHost
            }
            guard matches(session.username, pattern: "^[A-Za-z0-9._-]+$") else {
                throw SSHValidationError.invalidUsername
            }
        } else {
            guard matches(session.sshConfigAlias, pattern: "^[A-Za-z0-9._-]+$") else {
                throw SSHValidationError.invalidAlias
            }
        }
        if !allowPassword, session.authMethod == .password {
            throw SSHValidationError.passwordNotAllowed(purposeLabel)
        }
    }

    static func validate(tunnel: TunnelConfig) throws {
        guard isSafeForwardingHost(tunnel.listenHost),
              tunnel.type == .dynamic || isSafeForwardingHost(tunnel.remoteHost),
              (1...65535).contains(tunnel.localPort),
              tunnel.type == .dynamic || (1...65535).contains(tunnel.remotePort) else {
            throw SSHValidationError.invalidForwardingSpecification
        }
    }

    private static func sensitiveValues(for session: Session) -> [String] {
        [
            session.username,
            session.host,
            session.sshConfigAlias,
            session.privateKeyPath,
            session.remoteDirectory,
            session.screenSharingHost,
            session.remoteAccessAddress
        ].filter { !$0.isEmpty }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isSafeForwardingHost(_ value: String) -> Bool {
        !value.isEmpty &&
            value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\r\n,:")) == nil
    }
}
