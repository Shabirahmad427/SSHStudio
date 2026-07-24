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
    case requireKnownHost
    case useSSHStudioManagedKnownHosts
}

enum SSHAuthenticationMethod: Equatable {
    case password
    case privateKey(path: String)
    case sshAgent
    case macOSKeychain(path: String, addKeysToAgent: Bool)
    case sshConfigManaged
    case passwordCredential(referenceID: String)

    static func from(session: Session) -> Self {
        switch session.authentication {
        case .privateKey(let path, _, _, _):
            return path.isEmpty ? .sshAgent : .privateKey(path: path)
        case .sshAgent:
            return .sshAgent
        case .macOSKeychain(let path, let addKeysToAgent):
            return .macOSKeychain(path: path, addKeysToAgent: addKeysToAgent)
        case .passwordCredential(let referenceID):
            return .passwordCredential(referenceID: referenceID)
        case .sshConfigManaged:
            return .sshConfigManaged
        }
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
    let hostKeyPolicy: SSHHostKeyPolicy
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

    static func terminalInvocation(
        for session: Session,
        hostKeyPolicy: SSHHostKeyPolicy = .openSSHDefault
    ) throws -> SSHInvocation {
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
            hostKeyPolicy: hostKeyPolicy,
            sensitiveValues: sensitiveValues(for: session)
        )
    }

    static func tunnelInvocation(
        for tunnel: TunnelConfig,
        session: Session,
        hostKeyPolicy: SSHHostKeyPolicy = .openSSHDefault
    ) throws -> SSHInvocation {
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
            hostKeyPolicy: hostKeyPolicy,
            sensitiveValues: sensitiveValues(for: session)
        )
    }

    static func screenSharingTunnelInvocation(
        session: Session,
        displayHost: String,
        localPort: Int
    ) throws -> SSHInvocation {
        try validate(session: session, allowPassword: false, purposeLabel: "Screen sharing over SSH")
        guard isSafeForwardingHost(displayHost),
              (1...65535).contains(localPort),
              (1...65535).contains(session.screenSharingPort) else {
            throw SSHValidationError.invalidForwardingSpecification
        }
        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=8",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(SSHSecurity.controlPath(for: session))",
            "-L", "127.0.0.1:\(localPort):\(displayHost):\(session.screenSharingPort)"
        ]
        args += baseOptions
        args += destinationArgs(for: session)
        return SSHInvocation(
            purpose: .screenSharing,
            executableURL: sshExecutableURL,
            arguments: args,
            hostKeyPolicy: .openSSHDefault,
            sensitiveValues: sensitiveValues(for: session) + [displayHost]
        )
    }

    static func sftpInvocation(for session: Session, batchURL: URL? = nil) throws -> SSHInvocation {
        try validate(session: session, allowPassword: false, purposeLabel: "SFTP")
        var args: [String] = [
            "-B", SFTPManager.sftpBufferSize,
            "-R", SFTPManager.sftpRequestCount,
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(SSHSecurity.controlPath(for: session))",
            "-o", "ControlPersist=10m",
            "-o", "Compression=no",
            "-o", "IPQoS=throughput"
        ]
        args += baseOptions
        args += sftpDestinationArgs(for: session)
        if let batchURL {
            args.insert(contentsOf: ["-b", batchURL.path], at: 0)
        }
        return SSHInvocation(
            purpose: .sftp,
            executableURL: URL(fileURLWithPath: "/usr/bin/sftp"),
            arguments: args,
            hostKeyPolicy: .openSSHDefault,
            sensitiveValues: sensitiveValues(for: session) + [batchURL?.path].compactMap { $0 }
        )
    }

    static func rsyncSSHCommand(for session: Session, qos: String = "throughput") throws -> String {
        try validate(session: session, allowPassword: false, purposeLabel: "Sync")
        return rsyncSSHArgs(for: session, qos: qos).map(SSHSecurity.shellQuote).joined(separator: " ")
    }

    static func rsyncSSHArgs(for session: Session, qos: String = "throughput") -> [String] {
        var args = [
            "ssh",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(SSHSecurity.controlPath(for: session))",
            "-o", "Compression=no",
            "-o", "IPQoS=\(qos)"
        ]
        args += baseOptions
        args += authenticationArgs(for: session)
        args += ["-p", "\(session.port)"]
        return args
    }

    static func remoteCommandInvocation(for session: Session, command: String, purpose: SSHPurpose) throws -> SSHInvocation {
        try validate(session: session, allowPassword: false, purposeLabel: purpose.rawValue)
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(SSHSecurity.controlPath(for: session))",
            "-o", "ControlPersist=10m"
        ]
        args += baseOptions
        args += destinationArgs(for: session)
        args.append(command)
        return SSHInvocation(
            purpose: purpose,
            executableURL: sshExecutableURL,
            arguments: args,
            hostKeyPolicy: .openSSHDefault,
            sensitiveValues: sensitiveValues(for: session) + [command]
        )
    }

    static func destinationArgs(for session: Session) -> [String] {
        var args: [String] = []
        args += authenticationArgs(for: session)
        return args + ["-p", "\(session.port)", "--", connectionTarget(for: session)]
    }

    static func sftpDestinationArgs(for session: Session) -> [String] {
        var args: [String] = []
        args += authenticationArgs(for: session)
        return args + ["-P", "\(session.port)", connectionTarget(for: session)]
    }

    static func authenticationArgs(for session: Session) -> [String] {
        switch session.authentication {
        case .privateKey(let path, let useAgent, let addKeysToAgent, let useKeychain):
            var args = ["-o", "IdentitiesOnly=yes"]
            if useAgent {
                args += ["-o", "IdentityAgent=SSH_AUTH_SOCK"]
            }
            if addKeysToAgent {
                args += ["-o", "AddKeysToAgent=yes"]
            }
            if useKeychain {
                args += ["-o", "IgnoreUnknown=UseKeychain", "-o", "UseKeychain=yes"]
            }
            if !path.isEmpty {
                args += ["-i", path]
            }
            return args
        case .macOSKeychain(let path, let addKeysToAgent):
            var args = ["-o", "IgnoreUnknown=UseKeychain", "-o", "UseKeychain=yes", "-o", "IdentitiesOnly=yes"]
            if addKeysToAgent {
                args += ["-o", "AddKeysToAgent=yes"]
            }
            if !path.isEmpty {
                args += ["-i", path]
            }
            return args
        case .sshAgent:
            return ["-o", "IdentityAgent=SSH_AUTH_SOCK"]
        case .sshConfigManaged, .passwordCredential:
            return []
        }
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
        if !allowPassword, !session.authentication.isNonInteractiveCapable {
            throw SSHValidationError.passwordNotAllowed(purposeLabel)
        }
    }

    static func validateHostEndpoint(_ endpoint: SSHHostEndpoint) throws {
        guard (1...65535).contains(endpoint.port) else { throw SSHValidationError.invalidPort }
        guard matches(endpoint.hostname, pattern: "^[A-Za-z0-9._:\\[\\]-]+$") else {
            throw SSHValidationError.invalidHost
        }
        if let alias = endpoint.hostKeyAlias, !alias.isEmpty {
            guard matches(alias, pattern: "^[A-Za-z0-9._:\\[\\]-]+$") else {
                throw SSHValidationError.invalidAlias
            }
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
            session.authentication.privateKeyPath,
            session.authentication.credentialReferenceID ?? "",
            session.remoteStartDirectory,
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
