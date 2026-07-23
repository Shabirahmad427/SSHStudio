import Foundation

enum SyncDirection {
    case localToRemote
    case remoteToLocal
    case mirror // remote matches local exactly
    case serverToServer
}

@MainActor
class SyncManager: ObservableObject {
    @Published var isSyncing = false
    @Published var syncLog: [String] = []

    func sync(localPath: URL, remotePath: String, direction: SyncDirection,
              session: Session, completion: @escaping @MainActor () -> Void) {
        isSyncing = true
        syncLog = []

        let target = SSHSecurity.rsyncTarget(for: session)

        do {
            try SSHSecurity.validateNonInteractive(session: session, purpose: "Sync")
        } catch {
            isSyncing = false
            syncLog.append(error.localizedDescription)
            completion()
            return
        }
        let sshCmd = SSHSecurity.rsyncSSHArgs(for: session)
            .map(SSHSecurity.shellQuote)
            .joined(separator: " ")

        var args: [String] = ["-a", "--partial", "--progress", "-e", sshCmd]

        switch direction {
        case .localToRemote:
            args += [localPath.path + "/", remoteLocation(target: target, path: remotePath, trailingSlash: true)]
        case .remoteToLocal:
            args += [remoteLocation(target: target, path: remotePath, trailingSlash: true), localPath.path + "/"]
        case .mirror:
            args += ["--delete", localPath.path + "/", remoteLocation(target: target, path: remotePath, trailingSlash: true)]
        case .serverToServer:
            syncLog.append("Choose a destination server for server-to-server sync.")
            isSyncing = false
            completion()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = args

        let pipe = Pipe()
        let reader = PipeReader(pipe: pipe)
        process.standardOutput = pipe
        process.standardError = pipe

        let sessionName = session.name
        process.terminationHandler = { @Sendable p in
            reader.waitUntilFinished()
            Task { @MainActor in
                self.isSyncing = false
                if p.terminationStatus == 0 {
                    let msg = direction == .localToRemote ? "Sync local to remote complete" : "Sync remote to local complete"
                    ConnectionLog.shared.log(msg, level: .success, session: sessionName)
                } else {
                    let msg = "Sync failed with status \(p.terminationStatus)"
                    self.syncLog.append(msg)
                    ConnectionLog.shared.log(msg, level: .error, session: sessionName)
                }
                completion()
            }
        }

        ConnectionLog.shared.log("Starting sync: \(localPath.lastPathComponent) <-> \(remotePath)", session: session.name)
        do {
            try process.run()
            reader.start { data in
                if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                    Task { @MainActor [weak self] in self?.syncLog.append(line) }
                }
            }
        } catch {
            isSyncing = false
            syncLog.append("rsync not found. Install via: brew install rsync")
        }
    }

    func syncServerToServer(sourceSession: Session, sourcePath: String,
                            destinationSession: Session, destinationPath: String,
                            completion: @escaping @MainActor () -> Void) {
        isSyncing = true
        syncLog = []

        do {
            try SSHSecurity.validateNonInteractive(session: sourceSession, purpose: "Server-to-server sync")
            try SSHSecurity.validateNonInteractive(session: destinationSession, purpose: "Server-to-server sync")
        } catch {
            isSyncing = false
            syncLog.append(error.localizedDescription)
            completion()
            return
        }

        runSSHWithStatus(session: destinationSession, command: "mkdir -p -- \(SSHSecurity.remoteShellPath(destinationPath))") { [weak self] status, output in
            guard let self else {
                completion()
                return
            }
            guard status == 0 else {
                self.isSyncing = false
                self.syncLog.append(output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Could not create destination directory")
                completion()
                return
            }

            let destinationTarget = SSHSecurity.rsyncTarget(for: destinationSession)
            let sshArgs = SSHSecurity.rsyncSSHArgs(for: destinationSession)
                .map(SSHSecurity.shellQuote)
                .joined(separator: " ")
            let rsyncArgs = ["-a", "--partial", "--progress"]

            let args = rsyncArgs.map(SSHSecurity.shellQuote).joined(separator: " ")
            let source = Self.remoteShellPath(sourcePath, trailingSlash: true)
            let destination = Self.shellArgument(
                remoteLocation(target: destinationTarget, path: destinationPath, trailingSlash: true)
            )
            let command = "rsync \(args) -e \(SSHSecurity.shellQuote(sshArgs)) \(source) \(destination)"

            self.syncLog.append("Starting server-to-server sync: \(sourceSession.name):\(sourcePath) -> \(destinationSession.name):\(destinationPath)")
            ConnectionLog.shared.log(
                "Starting server-to-server sync: \(sourceSession.name):\(sourcePath) -> \(destinationSession.name):\(destinationPath)",
                session: sourceSession.name
            )

            self.runSSHWithStatus(session: sourceSession, command: command) { status, output in
                self.isSyncing = false
                if let output, !output.isEmpty {
                    self.syncLog.append(output)
                }
                if status == 0 {
                    ConnectionLog.shared.log(
                        "Server-to-server sync complete: \(sourceSession.name) -> \(destinationSession.name)",
                        level: .success,
                        session: sourceSession.name
                    )
                } else {
                    let message = "Server-to-server sync failed with status \(status)"
                    self.syncLog.append(message)
                    ConnectionLog.shared.log(message, level: .error, session: sourceSession.name)
                }
                completion()
            }
        }
    }

    private func runSSHWithStatus(session: Session, command: String,
                                  completion: @escaping @MainActor (Int32, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        do {
            try SSHSecurity.validateNonInteractive(session: session, purpose: "Sync")
        } catch {
            completion(255, error.localizedDescription)
            return
        }

        var args = ["-o", "BatchMode=yes",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(SSHSecurity.controlPath(for: session))",
                    "-o", "ControlPersist=10m"]
        args += SSHSecurity.baseOptions
        args += SSHSecurity.destinationArgs(for: session)
        args.append(command)
        process.arguments = args

        let pipe = Pipe()
        let reader = PipeReader(pipe: pipe)
        let output = SyncOutputBuffer()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { @Sendable p in
            reader.waitUntilFinished()
            let text = output.text()
            Task { @MainActor in
                completion(p.terminationStatus, text)
            }
        }

        do {
            try process.run()
            reader.start { data in
                output.append(data)
            }
        } catch {
            completion(255, error.localizedDescription)
        }
    }

    private func remoteLocation(target: String, path: String, trailingSlash: Bool) -> String {
        "\(target):\(Self.rsyncRemotePath(path, trailingSlash: trailingSlash))"
    }

    private static func remoteShellPath(_ path: String, trailingSlash: Bool) -> String {
        SSHSecurity.remoteShellPath(path) + (trailingSlash ? "/" : "")
    }

    private static func shellArgument(_ value: String) -> String {
        SSHSecurity.shellQuote(value)
    }

    private static func rsyncRemotePath(_ value: String, trailingSlash: Bool) -> String {
        let normalized = value.isEmpty ? "." : value
        let safeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-~")
        var escaped = ""
        for scalar in normalized.unicodeScalars {
            if safeCharacters.contains(scalar) {
                escaped.unicodeScalars.append(scalar)
            } else {
                escaped.append("\\")
                escaped.unicodeScalars.append(scalar)
            }
        }
        if trailingSlash, !escaped.hasSuffix("/") {
            escaped.append("/")
        }
        return escaped
    }
}

private final class SyncOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func text() -> String? {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8)
    }
}
