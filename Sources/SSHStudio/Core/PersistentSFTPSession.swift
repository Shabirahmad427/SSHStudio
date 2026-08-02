import Darwin
import Foundation

enum SFTPSessionError: LocalizedError {
    case connectionFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "SFTP connection failed: \(m)"
        case .notConnected: return "SFTP session not connected"
        }
    }
}

/// Keeps one sftp subprocess alive for the life of a session via a PTY.
///
/// A PTY (pseudo-terminal) makes sftp think it is talking to an interactive
/// terminal, so it runs in interactive mode: it prints "sftp> " prompts, supports
/// the "!" local-command escape, and does NOT exit when stdin goes quiet.
///
/// We use "!printf 'MARKER\n'" as a completion sentinel so we know exactly when
/// the previous command(s) finished — matching how Bitvise keeps one persistent
/// SFTP channel open instead of spawning a new process per file.
final class PersistentSFTPSession: @unchecked Sendable {
    private let sshSession: Session

    // All mutable state is touched only on `queue`
    private let queue = DispatchQueue(label: "com.sshstudio.sftp-session")
    private var process: Process?
    private var masterHandle: FileHandle?
    private var outputBuffer = ""
    private var isConnecting = false
    private let maxQueuedCommands: Int
    private let idleTimeout: TimeInterval
    private var idleTimer: DispatchSourceTimer?

    private enum Pending {
        case connecting(conts: [CheckedContinuation<Void, Error>])
        case command(marker: String, cont: CheckedContinuation<String, Error>)
    }
    private struct QueuedCommand {
        let input: String
        let marker: String
        let cont: CheckedContinuation<String, Error>
    }
    private var pending: Pending?
    private var commandQueue: [QueuedCommand] = []

    var isAlive: Bool { process?.isRunning ?? false }

    init(session: Session, maxQueuedCommands: Int = 64, idleTimeout: TimeInterval = 600) {
        self.sshSession = session
        self.maxQueuedCommands = maxQueuedCommands
        self.idleTimeout = idleTimeout
    }

    deinit { _tearDown() }

    // MARK: - Connect

    func connect() async throws {
        let allowed = await HostKeyVerificationGate.allowConnection(session: sshSession)
        if case .failure(let error) = allowed {
            throw error
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { self._launch(cont: cont) }
        }
    }

    private func _launch(cont: CheckedContinuation<Void, Error>) {
        if isAlive {
            cont.resume()
            return
        }
        if case .connecting(let conts) = pending {
            pending = .connecting(conts: conts + [cont])
            return
        }
        isConnecting = true

        // ── Remove stale control socket ───────────────────────────────────────
        // If a previous master died without cleaning up its socket file, ssh will
        // print "ControlSocket … already exists, disabling multiplexing" and skip
        // the mux — causing BatchMode connections to fail.  Check liveness first;
        // only unlink if the master is unresponsive.
        let sockPath = SSHSecurity.controlPath(for: sshSession)
        if FileManager.default.fileExists(atPath: sockPath) {
            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            check.arguments = ["-O", "check",
                               "-o", "ControlPath=\(sockPath)",
                               "-o", "ControlMaster=no",
                               SSHSecurity.connectionTarget(for: sshSession)]
            check.standardOutput = FileHandle.nullDevice
            check.standardError  = FileHandle.nullDevice
            try? check.run()
            check.waitUntilExit()
            if check.terminationStatus != 0 {
                try? FileManager.default.removeItem(atPath: sockPath)
            }
        }

        // ── Allocate PTY ──────────────────────────────────────────────────────
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0, grantpt(masterFD) == 0, unlockpt(masterFD) == 0,
              let slaveCStr = ptsname(masterFD) else {
            cont.resume(throwing: SFTPSessionError.connectionFailed("Could not allocate PTY"))
            return
        }
        let slaveFD = open(slaveCStr, O_RDWR | O_NOCTTY)
        guard slaveFD >= 0 else {
            close(masterFD)
            cont.resume(throwing: SFTPSessionError.connectionFailed("Could not open PTY slave"))
            return
        }

        // ── Configure sftp process ────────────────────────────────────────────
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        p.arguments = _buildArgs()

        // Child's stdin, stdout, stderr all go through the PTY slave.
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        p.standardInput  = slaveHandle
        p.standardOutput = slaveHandle
        p.standardError  = slaveHandle

        // Parent reads/writes through the master side.
        let mHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let reader = PipeReader(fileHandle: mHandle)

        p.terminationHandler = { [weak self] _ in
            reader.waitUntilFinished()
            guard let self else { return }
            self.queue.async { self._onProcessExit() }
        }

        do {
            try p.run()
            Task {
                await SFTPPerformanceRecorder.shared.recordProcessLaunch()
            }
            reader.start { [weak self] data in
                guard !data.isEmpty, let self else { return }
                let text = String(data: data, encoding: .utf8) ?? ""
                self.queue.async { self._onOutput(text) }
            }
        } catch {
            close(slaveFD)
            cont.resume(throwing: error)
            return
        }

        // Parent no longer needs the slave end.
        // The child (sftp) has it via its stdin/stdout/stderr.
        close(slaveFD)

        process = p
        masterHandle = mHandle

        // sftp will print "sftp> " once it is connected and ready.
        pending = .connecting(conts: [cont])
    }

    // MARK: - Execute

    /// Sends one or more sftp commands followed by a !printf sentinel and waits
    /// for the matching "sftp> " prompt. Returns the raw output between the
    /// sentinel and the previous prompt (mostly for diagnostics).
    func run(_ commands: String...) async throws -> String {
        try await run(commands)
    }

    func run(_ commands: [String]) async throws -> String {
        let marker = "SSHSTUDIO_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        // Send all commands then the sentinel !printf which confirms they all ran.
        let input = commands.joined(separator: "\n") + "\n!printf '\(marker)\\n'\n"

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.isAlive, self.masterHandle != nil else {
                    cont.resume(throwing: SFTPSessionError.notConnected)
                    return
                }
                let queued = QueuedCommand(input: input, marker: marker, cont: cont)
                if self.pending != nil {
                    guard self.commandQueue.count < self.maxQueuedCommands else {
                        cont.resume(throwing: SFTPSessionError.connectionFailed("SFTP operation queue is full"))
                        return
                    }
                    self.commandQueue.append(queued)
                } else {
                    self._start(queued)
                }
            }
        }
    }

    // MARK: - Output handling

    private func _onOutput(_ text: String) {
        outputBuffer += text
        switch pending {

        case .connecting(let conts):
            // sftp prints "sftp> " once the connection is established and it is ready.
            guard outputBuffer.contains("sftp> ") else { return }
            outputBuffer = ""
            pending = nil
            isConnecting = false
            conts.forEach { $0.resume() }
            _scheduleIdleTimeout()

        case .command(let marker, let cont):
            // We wait until:
            //   1. The marker (from !printf) appears in the output, AND
            //   2. An "sftp> " prompt appears after it (confirming sftp is ready again).
            guard outputBuffer.contains(marker) else { return }
            guard let markerRange = outputBuffer.range(of: marker),
                  outputBuffer[markerRange.upperBound...].contains("sftp> ") else { return }

            let output = String(outputBuffer[outputBuffer.startIndex..<markerRange.lowerBound])
            outputBuffer = ""
            pending = nil
            cont.resume(returning: output)
            _startNextCommandIfNeeded()
            if pending == nil {
                _scheduleIdleTimeout()
            }

        case nil:
            break
        }
    }

    private func _onProcessExit() {
        process = nil
        isConnecting = false
        switch pending {
        case .connecting(let conts):
            pending = nil
            conts.forEach { $0.resume(throwing: SFTPSessionError.connectionFailed("sftp exited during connect")) }
        case .command(_, let c):
            pending = nil
            c.resume(throwing: SFTPSessionError.notConnected)
        case nil:
            break
        }

        let queued = commandQueue
        commandQueue.removeAll()
        for command in queued {
            command.cont.resume(throwing: SFTPSessionError.notConnected)
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        queue.sync { _tearDown() }
    }

    private func _tearDown() {
        let queued = commandQueue
        commandQueue.removeAll()
        for command in queued {
            command.cont.resume(throwing: SFTPSessionError.notConnected)
        }
        switch pending {
        case .connecting(let conts):
            conts.forEach { $0.resume(throwing: SFTPSessionError.notConnected) }
        case .command(_, let cont):
            cont.resume(throwing: SFTPSessionError.notConnected)
        case nil:
            break
        }
        masterHandle?.closeFile()
        process?.terminate()
        process = nil
        masterHandle = nil
        pending = nil
        isConnecting = false
        idleTimer?.cancel()
        idleTimer = nil
    }

    // MARK: - Helpers

    private func _write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        masterHandle?.write(data)
    }

    private func _start(_ command: QueuedCommand) {
        idleTimer?.cancel()
        idleTimer = nil
        outputBuffer = ""
        pending = .command(marker: command.marker, cont: command.cont)
        _write(command.input)
    }

    private func _startNextCommandIfNeeded() {
        guard pending == nil, !commandQueue.isEmpty else { return }
        let next = commandQueue.removeFirst()
        _start(next)
    }

    private func _scheduleIdleTimeout() {
        idleTimer?.cancel()
        guard idleTimeout > 0, pending == nil, commandQueue.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in
            self?._tearDown()
        }
        idleTimer = timer
        timer.resume()
    }

    private func _buildArgs() -> [String] {
        (try? SSHCommandBuilder.sftpInvocation(for: sshSession).arguments) ?? SSHSecurity.destinationArgs(for: sshSession)
    }
}
