import Foundation

/// A minimal SFTP protocol v3 client (RFC draft-ietf-secsh-filexfer-02),
/// speaking the real binary SSH_FXP_* packet protocol over `ssh -s sftp`
/// instead of driving the interactive `sftp` CLI through a PTY and scraping
/// its text prompts.
///
/// Every request carries an explicit request ID and every response is
/// framed with an explicit 4-byte length prefix, so there is no prompt
/// detection, no partial-output ambiguity, and no dependence on directory
/// listing text happening to avoid characters that look like a shell
/// prompt. This is the same approach real SFTP clients (Bitvise, FileZilla,
/// Cyberduck, etc.) use.
enum SFTPBinaryError: LocalizedError, Equatable {
    case connectionFailed(String)
    case protocolError(String)
    case remoteError(code: UInt32, message: String)
    case notConnected
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "SFTP connection failed: \(m)"
        case .protocolError(let m): return "SFTP protocol error: \(m)"
        case .remoteError(let code, let message): return "SFTP error (\(code)): \(message)"
        case .notConnected: return "SFTP session not connected"
        case .requestTimeout: return "SFTP request timed out"
        }
    }

    /// Whether this failure indicates the binary channel itself is
    /// unusable (so the one-off text-batch fallback is worth trying)
    /// rather than a real error about the requested path.
    var allowsCompatibilityFallback: Bool {
        switch self {
        case .connectionFailed, .protocolError, .requestTimeout, .notConnected: return true
        case .remoteError: return false
        }
    }
}

struct SFTPBinaryEntry: Sendable, Equatable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64?
    let permissionsMode: UInt32?
    let modifiedDate: Date?
}

// MARK: - Wire format helpers

private struct SFTPPacketWriter {
    private(set) var body = Data()

    mutating func writeUInt32(_ value: UInt32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { body.append(contentsOf: $0) }
    }

    mutating func writeString(_ value: String) {
        let bytes = Array(value.utf8)
        writeUInt32(UInt32(bytes.count))
        body.append(contentsOf: bytes)
    }

    /// Wraps the accumulated body with the SFTP framing: 4-byte big-endian
    /// length (of type byte + payload) followed by the type byte.
    func framed(type: UInt8) -> Data {
        var out = Data()
        var length = UInt32(body.count + 1).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(type)
        out.append(body)
        return out
    }
}

private struct SFTPPacketReader {
    let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPBinaryError.protocolError("truncated uint32") }
        let bytes = data[offset..<offset + 4]
        offset += 4
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw SFTPBinaryError.protocolError("truncated uint64") }
        let bytes = data[offset..<offset + 8]
        offset += 8
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPBinaryError.protocolError("truncated byte") }
        let b = data[offset]
        offset += 1
        return b
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        guard remaining >= length else { throw SFTPBinaryError.protocolError("truncated string") }
        let bytes = data[offset..<offset + length]
        offset += length
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses an SFTPv3 ATTRS structure per the flags word.
    mutating func readAttrs() throws -> (size: UInt64?, permissions: UInt32?, mtime: UInt32?) {
        let flags = try readUInt32()
        var size: UInt64?
        var permissions: UInt32?
        var mtime: UInt32?
        if flags & 0x00000001 != 0 { size = try readUInt64() }
        if flags & 0x00000002 != 0 { _ = try readUInt32(); _ = try readUInt32() } // uid, gid
        if flags & 0x00000004 != 0 { permissions = try readUInt32() }
        if flags & 0x00000008 != 0 { _ = try readUInt32(); mtime = try readUInt32() } // atime, mtime
        if flags & 0x80000000 != 0 {
            let count = try readUInt32()
            for _ in 0..<count {
                _ = try readString()
                _ = try readString()
            }
        }
        return (size, permissions, mtime)
    }
}

// MARK: - Client

private enum SFTPPacketType: UInt8 {
    case initPacket = 1
    case version = 2
    case openPacket = 3
    case close = 4
    case opendir = 11
    case readdir = 12
    case realpath = 16
    case status = 101
    case handle = 102
    case name = 104
}

/// Keeps one `ssh -s sftp` subprocess alive for the life of a session,
/// speaking the binary SFTP protocol over plain (non-PTY) pipes.
final class SFTPBinaryClient: @unchecked Sendable {
    private let sshSession: Session
    private let queue = DispatchQueue(label: "com.sshstudio.sftp-binary")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<Data, Error>] = [:]
    private var connectContinuations: [CheckedContinuation<Void, Error>] = []
    private var isConnected = false
    private var connectFailure: Error?

    var isAlive: Bool { process?.isRunning ?? false }

    init(session: Session) {
        self.sshSession = session
    }

    deinit { _tearDown(with: SFTPBinaryError.notConnected) }

    // MARK: Connect

    func connect() async throws {
        let allowed = await HostKeyVerificationGate.allowConnection(session: sshSession)
        if case .failure(let error) = allowed {
            throw error
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { self._connect(cont: cont) }
        }
    }

    private func _connect(cont: CheckedContinuation<Void, Error>) {
        if isAlive, isConnected {
            cont.resume()
            return
        }
        connectContinuations.append(cont)
        guard connectContinuations.count == 1 else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = SSHCommandBuilder.baseOptions
            + ["-o", "BatchMode=yes"]
            + SSHCommandBuilder.authenticationArgs(for: sshSession)
            + ["-p", "\(sshSession.port)", "-s", "--", SSHCommandBuilder.connectionTarget(for: sshSession), "sftp"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice

        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            self?.queue.async { [weak self] in self?._onProcessExit(status: status) }
        }

        do {
            try p.run()
        } catch {
            _failConnect(error)
            return
        }

        process = p
        stdinHandle = stdinPipe.fileHandleForWriting
        let readHandle = stdoutPipe.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                self.queue.async { self._onEOF() }
                return
            }
            self.queue.async { self._onBytes(data) }
        }

        // SSH_FXP_INIT carries the client's supported protocol version.
        var writer = SFTPPacketWriter()
        writer.writeUInt32(3)
        _send(writer.framed(type: SFTPPacketType.initPacket.rawValue))
    }

    private func _failConnect(_ error: Error) {
        connectFailure = error
        let conts = connectContinuations
        connectContinuations.removeAll()
        conts.forEach { $0.resume(throwing: error) }
        _tearDown(with: error)
    }

    private func _onProcessExit(status: Int32) {
        let error = SFTPBinaryError.connectionFailed("ssh sftp subsystem exited (status \(status))")
        if !isConnected {
            _failConnect(error)
        } else {
            _tearDown(with: error)
        }
    }

    private func _onEOF() {
        let error = SFTPBinaryError.connectionFailed("connection closed")
        if !isConnected {
            _failConnect(error)
        } else {
            _tearDown(with: error)
        }
    }

    // MARK: Byte stream framing

    private func _onBytes(_ data: Data) {
        readBuffer.append(data)
        while true {
            guard readBuffer.count >= 4 else { return }
            let lengthBytes = readBuffer.prefix(4)
            let length = Int(lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard readBuffer.count >= 4 + length else { return }
            let packet = readBuffer.subdata(in: readBuffer.startIndex.advanced(by: 4)..<readBuffer.startIndex.advanced(by: 4 + length))
            readBuffer.removeSubrange(readBuffer.startIndex..<readBuffer.startIndex.advanced(by: 4 + length))
            _handlePacket(packet)
        }
    }

    private func _handlePacket(_ packet: Data) {
        guard let typeByte = packet.first, let type = SFTPPacketType(rawValue: typeByte) else { return }
        var reader = SFTPPacketReader(packet.dropFirst())

        if type == .version {
            isConnected = true
            let conts = connectContinuations
            connectContinuations.removeAll()
            conts.forEach { $0.resume() }
            return
        }

        guard let requestID = try? reader.readUInt32(), let cont = pending.removeValue(forKey: requestID) else { return }
        cont.resume(returning: packet)
    }

    // MARK: Requests

    private func _send(_ data: Data) {
        stdinHandle?.write(data)
    }

    private func _request(type: SFTPPacketType, body: SFTPPacketWriter, requestID: UInt32) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard self.isAlive, self.stdinHandle != nil else {
                    cont.resume(throwing: SFTPBinaryError.notConnected)
                    return
                }
                self.pending[requestID] = cont
                self._send(body.framed(type: type.rawValue))
            }
        }
    }

    private func _allocateRequestID() -> UInt32 {
        var id: UInt32 = 0
        queue.sync {
            id = nextRequestID
            nextRequestID += 1
        }
        return id
    }

    private func _requestIDField(into writer: inout SFTPPacketWriter, _ id: UInt32) {
        writer.writeUInt32(id)
    }

    private func _statusOrThrow(_ packet: Data, context: String) throws {
        guard let typeByte = packet.first, let type = SFTPPacketType(rawValue: typeByte), type == .status else {
            throw SFTPBinaryError.protocolError("unexpected response to \(context)")
        }
        var reader = SFTPPacketReader(packet.dropFirst())
        _ = try reader.readUInt32() // request id, already matched
        let code = try reader.readUInt32()
        let message = (try? reader.readString()) ?? ""
        guard code == 0 else {
            throw SFTPBinaryError.remoteError(code: code, message: message.isEmpty ? "SFTP error \(code)" : message)
        }
    }

    // MARK: Public operations

    func realPath(_ path: String) async throws -> String {
        let id = _allocateRequestID()
        var writer = SFTPPacketWriter()
        _requestIDField(into: &writer, id)
        writer.writeString(path)
        let packet = try await _request(type: .realpath, body: writer, requestID: id)
        guard let typeByte = packet.first, let type = SFTPPacketType(rawValue: typeByte) else {
            throw SFTPBinaryError.protocolError("unexpected realpath response")
        }
        if type == .status {
            try _statusOrThrow(packet, context: "realpath")
            throw SFTPBinaryError.protocolError("realpath returned status without name")
        }
        guard type == .name else { throw SFTPBinaryError.protocolError("unexpected realpath response type") }
        var reader = SFTPPacketReader(packet.dropFirst())
        _ = try reader.readUInt32() // request id
        let count = try reader.readUInt32()
        guard count >= 1 else { throw SFTPBinaryError.protocolError("realpath returned no entries") }
        let name = try reader.readString()
        _ = try? reader.readString() // longname
        _ = try? reader.readAttrs()
        return name
    }

    func listDirectory(path: String) async throws -> [SFTPBinaryEntry] {
        let openID = _allocateRequestID()
        var openWriter = SFTPPacketWriter()
        _requestIDField(into: &openWriter, openID)
        openWriter.writeString(path)
        let openResponse = try await _request(type: .opendir, body: openWriter, requestID: openID)
        guard let typeByte = openResponse.first, let type = SFTPPacketType(rawValue: typeByte), type == .handle else {
            try _statusOrThrow(openResponse, context: "opendir")
            throw SFTPBinaryError.protocolError("opendir did not return a handle")
        }
        var handleReader = SFTPPacketReader(openResponse.dropFirst())
        _ = try handleReader.readUInt32() // request id
        let handle = try handleReader.readString()

        var entries: [SFTPBinaryEntry] = []
        readLoop: while true {
            let readID = _allocateRequestID()
            var readWriter = SFTPPacketWriter()
            _requestIDField(into: &readWriter, readID)
            readWriter.writeString(handle)
            let response: Data
            do {
                response = try await _request(type: .readdir, body: readWriter, requestID: readID)
            } catch {
                break readLoop
            }
            guard let respType = response.first.flatMap(SFTPPacketType.init) else {
                throw SFTPBinaryError.protocolError("unexpected readdir response")
            }
            if respType == .status {
                // SSH_FX_EOF (code 1) is the normal end-of-listing signal.
                var statusReader = SFTPPacketReader(response.dropFirst())
                _ = try statusReader.readUInt32()
                let code = try statusReader.readUInt32()
                if code == 1 { break readLoop }
                let message = (try? statusReader.readString()) ?? "readdir failed"
                throw SFTPBinaryError.remoteError(code: code, message: message)
            }
            guard respType == .name else {
                throw SFTPBinaryError.protocolError("unexpected readdir response type")
            }
            var reader = SFTPPacketReader(response.dropFirst())
            _ = try reader.readUInt32()
            let count = try reader.readUInt32()
            for _ in 0..<count {
                let name = try reader.readString()
                _ = try reader.readString() // longname, unused — we build display fields from attrs
                let attrs = try reader.readAttrs()
                if name == "." || name == ".." { continue }
                let mode = attrs.permissions
                let isDir = mode.map { ($0 & 0xF000) == 0x4000 } ?? false
                let isLink = mode.map { ($0 & 0xF000) == 0xA000 } ?? false
                entries.append(SFTPBinaryEntry(
                    name: name,
                    isDirectory: isDir,
                    isSymlink: isLink,
                    size: attrs.size,
                    permissionsMode: mode,
                    modifiedDate: attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                ))
            }
        }

        let closeID = _allocateRequestID()
        var closeWriter = SFTPPacketWriter()
        _requestIDField(into: &closeWriter, closeID)
        closeWriter.writeString(handle)
        _ = try? await _request(type: .close, body: closeWriter, requestID: closeID)

        return entries
    }

    // MARK: Teardown

    func disconnect() {
        queue.sync { _tearDown(with: SFTPBinaryError.notConnected) }
    }

    private func _tearDown(with error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        let conts = connectContinuations
        connectContinuations.removeAll()
        conts.forEach { $0.resume(throwing: error) }
        process?.terminate()
        process = nil
        stdinHandle = nil
        isConnected = false
        readBuffer.removeAll()
    }
}

extension SFTPBinaryEntry {
    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    /// Renders a unix `ls -la`-style permission string (e.g. "drwxr-xr-x")
    /// so the rest of the app — the file browser rows and the chmod sheet —
    /// doesn't need to know whether the listing came from the binary
    /// protocol or the text-batch fallback.
    private var permissionsDisplayString: String {
        let typeChar: Character = isSymlink ? "l" : (isDirectory ? "d" : "-")
        guard let mode = permissionsMode else {
            return isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        }
        let bits: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x")
        ]
        var chars = [typeChar]
        for (mask, ch) in bits {
            chars.append(mode & mask != 0 ? ch : "-")
        }
        return String(chars)
    }

    func asRemoteFile() -> RemoteFile {
        RemoteFile(
            name: name,
            isDirectory: isDirectory,
            size: size.map(String.init) ?? "",
            permissions: permissionsDisplayString,
            modified: modifiedDate.map { Self.modifiedFormatter.string(from: $0) } ?? "",
            modifiedDate: modifiedDate
        )
    }
}
