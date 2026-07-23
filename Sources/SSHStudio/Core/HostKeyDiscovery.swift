import Foundation

protocol HostKeyDiscovery: Sendable {
    func scan(endpoint: SSHHostEndpoint) async throws -> [SSHHostKeyCandidate]
}

struct SSHKeyscanProcessAdapter: HostKeyDiscovery {
    var timeout: TimeInterval = 8
    var maxOutputBytes: Int = 64 * 1024

    func scan(endpoint: SSHHostEndpoint) async throws -> [SSHHostKeyCandidate] {
        try SSHCommandBuilder.validateHostEndpoint(endpoint)
        let processBox = ProcessBox()
        return try await withTaskCancellationHandler {
            try await runScan(endpoint: endpoint, processBox: processBox)
        } onCancel: {
            processBox.terminate()
        }
    }

    private func runScan(endpoint: SSHHostEndpoint, processBox: ProcessBox) async throws -> [SSHHostKeyCandidate] {
        let process = Process()
        processBox.process = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        var args = ["-T", "\(max(1, Int(timeout)))"]
        if endpoint.port != 22 {
            args += ["-p", "\(endpoint.port)"]
        }
        args.append(endpoint.hostname)
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let output = BoundedProcessOutput(maxBytes: maxOutputBytes)
        let errorOutput = BoundedProcessOutput(maxBytes: 16 * 1024)

        return try await withCheckedThrowingContinuation { continuation in
            let finished = LockedFlag()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard finished.setIfUnset() else { return }
                process.terminate()
                continuation.resume(throwing: SSHHostKeyError.timeout)
            }

            process.terminationHandler = { _ in
                timer.cancel()
                guard finished.setIfUnset() else { return }
                do {
                    let candidates = try Self.parseScanOutput(output.data(), endpoint: endpoint)
                    if candidates.isEmpty {
                        let message = String(data: errorOutput.data(), encoding: .utf8) ?? ""
                        throw SSHHostKeyError.store(DiagnosticRedactor.redact(message.isEmpty ? "No host keys found." : message))
                    }
                    continuation.resume(returning: candidates)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
                timer.resume()
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    output.append(handle.availableData)
                    if output.isOversized {
                        process.terminate()
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    errorOutput.append(handle.availableData)
                }
            } catch {
                timer.cancel()
                continuation.resume(throwing: SSHHostKeyError.store(error.localizedDescription))
            }
        }
    }

    static func parseScanOutput(_ data: Data, endpoint: SSHHostEndpoint) throws -> [SSHHostKeyCandidate] {
        guard data.count <= 64 * 1024 else { throw SSHHostKeyError.oversizedOutput }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SSHHostKeyError.malformedScanOutput
        }
        var candidates: [SSHHostKeyCandidate] = []
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { throw SSHHostKeyError.malformedScanOutput }
            let algorithm = SSHHostKeyAlgorithm(rawOpenSSHValue: parts[1])
            guard algorithm != .unknown else { throw SSHHostKeyError.malformedScanOutput }
            let publicKey = parts[2]
            let fingerprint = try SSHHostFingerprint.computeSHA256(publicKeyBase64: publicKey)
            candidates.append(SSHHostKeyCandidate(
                endpoint: endpoint,
                algorithm: algorithm,
                publicKey: publicKey,
                fingerprint: fingerprint
            ))
        }
        return candidates
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    var process: Process? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
    private var stored: Process?

    func terminate() {
        process?.terminate()
    }
}

final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var storage = Data()
    private(set) var isOversized = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if storage.count + data.count > maxBytes {
            isOversized = true
            return
        }
        storage.append(data)
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
