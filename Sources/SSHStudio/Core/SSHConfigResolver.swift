import Foundation

struct SSHConfigResolution: Sendable, Equatable {
    var requestedHost: String
    var resolvedHostName: String
    var port: Int?
    var hostKeyAlias: String?
    var proxyJump: String?
    var proxyCommand: String?

    var usesAliasResolution: Bool {
        !resolvedHostName.isEmpty && resolvedHostName != requestedHost
    }

    var usesProxyRouting: Bool {
        let jump = proxyJump?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = proxyCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!jump.isEmpty && jump != "none") || (!command.isEmpty && command != "none")
    }

    var requiresOpenSSHManagedVerification: Bool {
        usesAliasResolution || usesProxyRouting || hostKeyAlias?.isEmpty == false
    }
}

protocol SSHConfigResolving: Sendable {
    func resolve(host: String) async -> SSHConfigResolution?
}

struct OpenSSHConfigResolver: SSHConfigResolving {
    func resolve(host: String) async -> SSHConfigResolution? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", host]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return Self.parse(data: data, requestedHost: host)
        } catch {
            return nil
        }
    }

    static func parse(data: Data, requestedHost: String) -> SSHConfigResolution? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].lowercased()] = parts[1]
        }
        return SSHConfigResolution(
            requestedHost: requestedHost,
            resolvedHostName: values["hostname"] ?? requestedHost,
            port: values["port"].flatMap(Int.init),
            hostKeyAlias: values["hostkeyalias"],
            proxyJump: values["proxyjump"],
            proxyCommand: values["proxycommand"]
        )
    }
}
