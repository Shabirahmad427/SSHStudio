import Foundation

struct RemoteFile: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: String
    let permissions: String
    let modified: String
    let modifiedDate: Date?

    init(
        id: String? = nil,
        name: String,
        isDirectory: Bool,
        size: String,
        permissions: String,
        modified: String,
        modifiedDate: Date?
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.permissions = permissions
        self.modified = modified
        self.modifiedDate = modifiedDate
        self.id = id ?? "\(isDirectory ? "d" : "f")|\(name)|\(size)|\(permissions)|\(modified)"
    }
}

enum SFTPDiagnosticStatus: String, Equatable, Sendable {
    case persistentActive = "Persistent session active"
    case compatibilityFallbackActive = "Compatibility fallback active"
    case authenticationFailed = "Authentication failed"
    case hostVerificationRequired = "Host verification required"
    case connectionUnavailable = "Connection unavailable"
}

@MainActor
class SFTPManager: ObservableObject {
    @Published var files: [RemoteFile] = []
    @Published var currentPath: String = "~"
    @Published var isLoading = false
    @Published var error: String?
    @Published var showHiddenFiles = false
    @Published var isShowingCachedListing = false
    @Published var listingStatus: String = ""
    @Published var diagnosticStatus: SFTPDiagnosticStatus?

    let fileSync = TempFileSync()
    let history = NavigationHistory<String>(initial: "~")
    private var session: Session?
    private var hasConnected = false
    private var dirCache = SFTPDirectoryCache()
    private var persistentSFTP: PersistentSFTPSession?
    private var persistentCapability = SFTPPersistentCapabilityCircuitBreaker()
    private var activeListingTask: Task<Void, Never>?
    private var activeListingRequestID: UInt64 = 0
    private var inFlightListingKeys: Set<SFTPListingCacheKey> = []
    private var refreshTask: Task<Void, Never>?
    nonisolated static let sftpBufferSize = "65536"
    nonisolated static let sftpRequestCount = "256"
    nonisolated static func sftpListCommand(path: String) throws -> String {
        let path = try SFTPPath(path)
        var commands = sftpDirectoryCommands(for: path.rawValue)
        commands += ["pwd", "ls -la ."]
        return commands.joined(separator: "\n")
    }

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    nonisolated static func childPath(parent: String, child: String) -> String {
        switch parent {
        case "", ".":
            return child
        case "/", "~":
            return "\(parent)/\(child)"
        default:
            let base = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
            return "\(base)/\(child)"
        }
    }

    func connect(to session: Session) {
        let startPath = Self.startDirectory(for: session)
        if hasConnected, self.session?.id == session.id {
            self.session = session
            if (currentPath == "~" || currentPath == ".") && currentPath != startPath {
                currentPath = startPath
                history.reset(to: startPath)
                listFiles(at: startPath, pushHistory: false)
            }
            return
        }
        // Tear down the old persistent session whenever the target server changes.
        persistentSFTP?.disconnect()
        persistentSFTP = nil
        persistentCapability.resetAll()
        diagnosticStatus = nil
        activeListingTask?.cancel()
        activeListingTask = nil
        dirCache.removeAll()
        self.session = session
        hasConnected = true
        currentPath = startPath
        history.reset(to: startPath)
        listFiles(at: startPath, pushHistory: false)
    }

    static func startDirectory(for session: Session) -> String {
        let configured = session.remoteStartDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacy = session.remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = configured.isEmpty ? legacy : configured
        return (try? SFTPPath(candidate).rawValue) ?? SFTPPath.home.rawValue
    }

    func goHome(for session: Session) {
        listFiles(at: Self.startDirectory(for: session))
    }

    /// Returns the live persistent SFTP session, connecting it lazily on first use.
    private func getPersistentSFTP(for session: Session) async throws -> PersistentSFTPSession {
        if !persistentCapability.shouldAttemptPersistent(profileID: session.id) {
            throw SFTPSessionError.compatibilityUnavailable("persistent startup disabled for this app session")
        }
        if let existing = persistentSFTP, existing.isAlive { return existing }
        persistentSFTP?.disconnect()
        let sftp = PersistentSFTPSession(session: session)
        try await sftp.connect()
        persistentSFTP = sftp
        diagnosticStatus = .persistentActive
        return sftp
    }

    func listFiles(at path: String, pushHistory: Bool = true, forceRefresh: Bool = false) {
        guard let session else { return }
        error = nil
        let normalizedPath = Self.normalizedRemotePath(path)
        let cacheKey = SFTPListingCacheKey(
            profileID: session.id,
            normalizedPath: normalizedPath,
            options: SFTPListingOptions(showHiddenFiles: showHiddenFiles)
        )

        if inFlightListingKeys.contains(cacheKey), !forceRefresh {
            if dirCache.value(for: cacheKey) == nil {
                isLoading = true
                listingStatus = "Loading"
            }
            return
        }

        let requestID = activeListingRequestID + 1
        activeListingRequestID = requestID

        if let cached = dirCache.value(for: cacheKey) {
            applyListing(cached.files, path: normalizedPath, pushHistory: pushHistory, requestID: requestID, cached: true)
            if cached.isFresh, !forceRefresh {
                listingStatus = "Cached"
                return
            }
            isShowingCachedListing = true
            listingStatus = "Refreshing"
        } else {
            isLoading = true
            isShowingCachedListing = false
            listingStatus = "Loading"
        }

        activeListingTask?.cancel()
        activeListingTask = Task { [weak self] in
            guard let self else { return }
            await self.loadListing(
                session: session,
                path: normalizedPath,
                cacheKey: cacheKey,
                requestID: requestID,
                pushHistory: pushHistory
            )
        }
    }

    private func loadListing(
        session: Session,
        path: String,
        cacheKey: SFTPListingCacheKey,
        requestID: UInt64,
        pushHistory: Bool
    ) async {
        inFlightListingKeys.insert(cacheKey)
        defer { inFlightListingKeys.remove(cacheKey) }

        let listStart = ContinuousClock.now
        do {
            let sftp = try await getPersistentSFTP(for: session)
            let output = try await sftp.run(Self.sftpListCommand(path: path))
            try Task.checkCancellation()
            let parseStart = ContinuousClock.now
            let resolvedPath = Self.resolvedPath(from: output) ?? path
            let parsed = await Task.detached(priority: .userInitiated) {
                Self.parse(lsOutput: output)
            }.value
            await SFTPPerformanceRecorder.shared.record(.parsing, start: parseStart, entryCount: parsed.count, requestID: requestID)
            try Task.checkCancellation()

            guard requestID == activeListingRequestID else { return }
            let wasFirstListing = files.isEmpty
            dirCache.set(parsed, for: cacheKey)
            applyListing(parsed, path: resolvedPath, pushHistory: pushHistory, requestID: requestID, cached: false)
            let phase: SFTPPerformancePhase = wasFirstListing ? .firstDirectoryListing : .subsequentDirectoryListing
            await SFTPPerformanceRecorder.shared.record(phase, start: listStart, entryCount: parsed.count, requestID: requestID, cacheState: "network")
        } catch is CancellationError {
            if requestID == activeListingRequestID {
                isLoading = false
                listingStatus = ""
            }
        } catch let error as SFTPSessionError where error.allowsCompatibilityFallback {
            persistentSFTP?.disconnectAndWait()
            persistentSFTP = nil
            cleanupPersistentControlSocket(for: session)
            persistentCapability.markCompatibilityUnavailable(profileID: session.id)
            diagnosticStatus = .compatibilityFallbackActive
            await loadListingWithOneOffFallback(
                session: session,
                path: path,
                cacheKey: cacheKey,
                requestID: requestID,
                pushHistory: pushHistory,
                listStart: listStart
            )
        } catch let error as SFTPSessionError {
            if requestID == activeListingRequestID {
                persistentSFTP?.disconnect()
                persistentSFTP = nil
                isLoading = false
                isShowingCachedListing = false
                listingStatus = ""
                switch error {
                case .authenticationFailed:
                    diagnosticStatus = .authenticationFailed
                case .hostVerificationFailed:
                    diagnosticStatus = .hostVerificationRequired
                default:
                    diagnosticStatus = .connectionUnavailable
                }
                let message = DiagnosticRedactor.redact(error.localizedDescription)
                self.error = message.isEmpty ? "Failed to list files" : message
            }
        } catch {
            if requestID == activeListingRequestID {
                persistentSFTP?.disconnect()
                persistentSFTP = nil
                isLoading = false
                isShowingCachedListing = false
                listingStatus = ""
                let message = DiagnosticRedactor.redact(error.localizedDescription)
                self.error = message.isEmpty ? "Failed to list files" : message
            }
        }
    }

    private func loadListingWithOneOffFallback(
        session: Session,
        path: String,
        cacheKey: SFTPListingCacheKey,
        requestID: UInt64,
        pushHistory: Bool,
        listStart: ContinuousClock.Instant
    ) async {
        let listCommand: String
        do {
            listCommand = try Self.sftpListCommand(path: path)
        } catch {
            guard requestID == activeListingRequestID else { return }
            isLoading = false
            isShowingCachedListing = false
            listingStatus = ""
            diagnosticStatus = .connectionUnavailable
            self.error = error.localizedDescription
            return
        }
        let result = await runSFTPBatchListing(session: session, listCommand: listCommand)
        guard requestID == activeListingRequestID else { return }
        guard result.status == 0, let output = result.output else {
            isLoading = false
            isShowingCachedListing = false
            listingStatus = ""
            diagnosticStatus = .connectionUnavailable
            let detail = result.output?.trimmingCharacters(in: .whitespacesAndNewlines)
            error = detail?.isEmpty == false ? DiagnosticRedactor.redact(detail!) : "Failed to list files"
            return
        }

        let parseStart = ContinuousClock.now
        let resolvedPath = Self.resolvedPath(from: output) ?? path
        let parsed = await Task.detached(priority: .userInitiated) {
            Self.parse(lsOutput: output)
        }.value
        await SFTPPerformanceRecorder.shared.record(.parsing, start: parseStart, entryCount: parsed.count, requestID: requestID, cacheState: "fallback")
        guard requestID == activeListingRequestID else { return }
        let wasFirstListing = files.isEmpty
        dirCache.set(parsed, for: cacheKey)
        applyListing(parsed, path: resolvedPath, pushHistory: pushHistory, requestID: requestID, cached: false)
        diagnosticStatus = .compatibilityFallbackActive
        let phase: SFTPPerformancePhase = wasFirstListing ? .firstDirectoryListing : .subsequentDirectoryListing
        await SFTPPerformanceRecorder.shared.record(phase, start: listStart, entryCount: parsed.count, requestID: requestID, cacheState: "fallback")
    }

    private func runSFTPBatchListing(session: Session, listCommand: String) async -> (status: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            let batchURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ssh-studio-sftp-list-\(UUID().uuidString).batch")
            do {
                try ("\(listCommand)\n").write(to: batchURL, atomically: true, encoding: .utf8)
            } catch {
                continuation.resume(returning: (255, DiagnosticRedactor.redact(error.localizedDescription)))
                return
            }

            let process = Process()
            do {
                let invocation = try SSHCommandBuilder.sftpInvocation(for: session, batchURL: batchURL)
                process.executableURL = invocation.executableURL
                process.arguments = Self.isolatedOneOffSFTPArguments(from: invocation.arguments)
            } catch {
                try? FileManager.default.removeItem(at: batchURL)
                continuation.resume(returning: (255, DiagnosticRedactor.redact(error.localizedDescription)))
                return
            }

            let pipe = Pipe()
            let reader = PipeReader(pipe: pipe)
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { @Sendable process in
                let data = reader.collectedData()
                let output = String(data: data, encoding: .utf8)
                try? FileManager.default.removeItem(at: batchURL)
                Task {
                    await SFTPPerformanceRecorder.shared.recordProcessLaunch()
                    continuation.resume(returning: (process.terminationStatus, output))
                }
            }

            Task { @MainActor in
                switch await HostKeyVerificationGate.allowConnection(session: session) {
                case .success:
                    do {
                        try process.run()
                        reader.start()
                    } catch {
                        try? FileManager.default.removeItem(at: batchURL)
                        continuation.resume(returning: (255, DiagnosticRedactor.redact(error.localizedDescription)))
                    }
                case .failure(let error):
                    try? FileManager.default.removeItem(at: batchURL)
                    continuation.resume(returning: (255, error.localizedDescription))
                }
            }
        }
    }

    private func cleanupPersistentControlSocket(for session: Session) {
        let sockPath = SSHSecurity.controlPath(for: session)
        guard FileManager.default.fileExists(atPath: sockPath) else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        check.arguments = [
            "-O", "check",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "ControlPath=\(sockPath)",
            SSHSecurity.connectionTarget(for: session)
        ]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do {
            try check.run()
            check.waitUntilExit()
            if check.terminationStatus != 0 {
                try? FileManager.default.removeItem(atPath: sockPath)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: sockPath)
        }
    }

    nonisolated static func isolatedOneOffSFTPArguments(from arguments: [String]) -> [String] {
        arguments.map { arg in
            switch arg {
            case "ControlMaster=auto", "ControlMaster=yes":
                return "ControlMaster=no"
            case let value where value.hasPrefix("ControlPersist="):
                return "ControlPersist=no"
            case let value where value.hasPrefix("ControlPath="):
                return "ControlPath=none"
            default:
                return arg
            }
        }
    }

    private func applyListing(
        _ newFiles: [RemoteFile],
        path: String,
        pushHistory: Bool,
        requestID: UInt64,
        cached: Bool
    ) {
        guard requestID == activeListingRequestID else { return }
        let start = ContinuousClock.now
        files = newFiles
        if pushHistory { history.navigate(to: path) }
        currentPath = path
        isLoading = false
        isShowingCachedListing = cached
        listingStatus = cached ? "Cached" : ""
        Task {
            await SFTPPerformanceRecorder.shared.record(.mainActorUpdate, start: start, entryCount: newFiles.count, requestID: requestID, cacheState: cached ? "cache" : "network")
        }
    }

    func goBack() {
        history.goBack()
        listFiles(at: history.current, pushHistory: false)
    }

    func goForward() {
        history.goForward()
        listFiles(at: history.current, pushHistory: false)
    }

    func download(file: RemoteFile, to localURL: URL, session: Session, completion: (@MainActor () -> Void)? = nil) {
        download(
            remotePath: Self.childPath(parent: currentPath, child: file.name),
            name: file.name,
            isDirectory: file.isDirectory,
            to: localURL,
            session: session,
            completion: completion
        )
    }

    func download(remotePath: String, name: String, isDirectory: Bool, to localURL: URL,
                  session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        let item = TransferItem(name: name, direction: .download)
        TransferQueue.shared.add(item)

        guard !isDirectory else {
            downloadDirectoryTree(
                remotePath: remotePath,
                name: name,
                to: localURL,
                session: session,
                item: item,
                completion: completion
            )
            return
        }

        // Single-file download via persistent SFTP — no handshake overhead.
        item.status = .inProgress
        item.startedAt = Date()
        item.profileLabel = "SFTP transfer"
        let stagedURL = localURL.deletingLastPathComponent()
            .appendingPathComponent(".\(localURL.lastPathComponent).sshstudio-download-partial")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sftp = try await getPersistentSFTP(for: session)
                ConnectionLog.shared.log("Starting download: \(name)", level: .info, session: session.name)
                _ = try await sftp.run(
                    "get -a \(Self.sftpRemotePath(remotePath)) \(Self.sftpLocalPath(stagedURL.path))"
                )
                self._finaliseDownload(stagedURL: stagedURL, localURL: localURL, name: name,
                                       item: item, session: session, completion: completion)
            } catch {
                // Persistent session failed — drop it and fall back to subprocess.
                persistentSFTP?.disconnect()
                persistentSFTP = nil
                ConnectionLog.shared.log(
                    "Persistent SFTP download failed for \(name); falling back to subprocess",
                    level: .warning, session: session.name
                )
                sftpTransfer(
                    command: "get -a \(Self.sftpRemotePath(remotePath)) \(Self.sftpLocalPath(stagedURL.path))",
                    session: session, item: item, isDirectory: false
                ) { succeeded in
                    guard succeeded else { return }
                    self._finaliseDownload(stagedURL: stagedURL, localURL: localURL, name: name,
                                          item: item, session: session, completion: completion)
                }
            }
        }
    }

    private func _finaliseDownload(stagedURL: URL, localURL: URL, name: String,
                                   item: TransferItem, session: Session,
                                   completion: (@MainActor () -> Void)?) {
        do {
            let parentDir = localURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: stagedURL, to: localURL)
            item.status = .completed
            item.percentDone = 100
            item.bytesTransferred = max(item.bytesTransferred, item.totalBytes)
            ConnectionLog.shared.log(
                "Downloaded \(name) to \(localURL.path)\(Self.transferSizeSuffix(for: item))",
                level: .success, session: session.name
            )
            completion?()
        } catch {
            let message = "Downloaded, but could not replace the existing local item: \(error.localizedDescription)"
            item.status = .failed(message)
            ConnectionLog.shared.log("Download failed for \(name): \(message)", level: .error, session: session.name)
        }
    }

    private struct RemoteDownloadEntry {
        let remotePath: String
        let localURL: URL
    }

    private struct RemoteDownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func downloadDirectoryTree(remotePath: String, name: String, to localURL: URL,
                                       session: Session, item: TransferItem,
                                       completion: (@MainActor () -> Void)?) {
        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            item.status = .failed("Could not create local folder: \(error.localizedDescription)")
            completion?()
            return
        }

        item.profileLabel = "Fast folder download"
        rsyncTransfer(
            from: remoteLocation(session: session, path: remotePath),
            to: localURL.deletingLastPathComponent().path,
            session: session,
            item: item,
            completeOnSuccess: true,
            isDirectory: true
        ) { [weak self] succeeded in
            guard let self else {
                completion?()
                return
            }
            if succeeded {
                ConnectionLog.shared.log(
                    "Downloaded folder \(name) to \(localURL.path)\(Self.transferSizeSuffix(for: item))",
                    level: .success,
                    session: session.name
                )
                completion?()
                return
            }

            ConnectionLog.shared.log(
                "Fast folder download failed for \(name); retrying with SFTP",
                level: .warning,
                session: session.name
            )
            self.downloadDirectoryTreeWithSFTP(
                remotePath: remotePath,
                name: name,
                to: localURL,
                session: session,
                item: item,
                completion: completion
            )
        }
    }

    private func downloadDirectoryTreeWithSFTP(remotePath: String, name: String, to localURL: URL,
                                               session: Session, item: TransferItem,
                                               completion: (@MainActor () -> Void)?) {
        expandRemoteDirectory(remotePath: remotePath, localRoot: localURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let message):
                item.status = .failed(message.localizedDescription)
                completion?()

            case .success(let expanded):
                do {
                    try self.createLocalDirectories(expanded.directories)
                } catch {
                    item.status = .failed("Could not create local folders: \(error.localizedDescription)")
                    completion?()
                    return
                }

                guard !expanded.files.isEmpty else {
                    item.status = .completed
                    item.percentDone = 100
                    ConnectionLog.shared.log(
                        "Created local folder \(localURL.path)",
                        level: .success,
                        session: session.name
                    )
                    completion?()
                    return
                }

                self.downloadExpandedFiles(expanded.files, item: item, session: session) { succeeded in
                    if succeeded {
                        item.status = .completed
                        item.percentDone = 100
                        ConnectionLog.shared.log(
                            "Downloaded folder \(name) to \(localURL.path)",
                            level: .success,
                            session: session.name
                        )
                    }
                    completion?()
                }
            }
        }
    }

    private func expandAndDownloadRemoteItems(
        remoteItems: [(remotePath: String, name: String, isDirectory: Bool)],
        to localURL: URL,
        session: Session,
        item: TransferItem,
        completion: (@MainActor () -> Void)?
    ) {
        var pending = remoteItems.count
        var directories: [URL] = []
        var files: [RemoteDownloadEntry] = []
        var failure: String?

        func finishOne() {
            pending -= 1
            guard pending == 0 else { return }
            if let failure {
                item.status = .failed(failure)
                completion?()
                return
            }
            do {
                try createLocalDirectories(directories)
            } catch {
                item.status = .failed("Could not create local folders: \(error.localizedDescription)")
                completion?()
                return
            }
            guard !files.isEmpty else {
                item.status = .completed
                item.percentDone = 100
                completion?()
                return
            }
            downloadExpandedFiles(files, item: item, session: session) { succeeded in
                if succeeded {
                    item.status = .completed
                    item.percentDone = 100
                    ConnectionLog.shared.log(
                        "Downloaded \(remoteItems.count) item\(remoteItems.count == 1 ? "" : "s") to \(localURL.path)",
                        level: .success,
                        session: session.name
                    )
                }
                completion?()
            }
        }

        for remoteItem in remoteItems {
            let destination = localURL.appendingPathComponent(remoteItem.name)
            if remoteItem.isDirectory {
                expandRemoteDirectory(remotePath: remoteItem.remotePath, localRoot: destination) { result in
                    switch result {
                    case .failure(let message):
                        failure = message.localizedDescription
                    case .success(let expanded):
                        directories.append(contentsOf: expanded.directories)
                        files.append(contentsOf: expanded.files)
                    }
                    finishOne()
                }
            } else {
                files.append(RemoteDownloadEntry(remotePath: remoteItem.remotePath, localURL: destination))
                finishOne()
            }
        }
    }

    private func expandRemoteDirectory(
        remotePath: String,
        localRoot: URL,
        completion: @escaping @MainActor (Result<(directories: [URL], files: [RemoteDownloadEntry]), RemoteDownloadError>) -> Void
    ) {
        guard let session = self.session else {
            completion(.failure(RemoteDownloadError(message: "No active SFTP session")))
            return
        }

        let marker = "__SSHSTUDIO_FILES__"
        let root = SSHSecurity.remoteShellPath(remotePath)
        let command = "find \(root) -type d -print && printf '\\n\(marker)\\n' && find \(root) -type f -print"
        runSSHWithStatus(session: session, command: command) { status, output in
            guard status == 0, let output else {
                completion(.failure(RemoteDownloadError(message: "Could not list remote folder")))
                return
            }
            let parts = output.components(separatedBy: "\n\(marker)\n")
            guard parts.count == 2 else {
                completion(.failure(RemoteDownloadError(message: "Could not parse remote folder listing")))
                return
            }

            let remoteRoot = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
            let directoryURLs = parts[0]
                .split(separator: "\n")
                .map(String.init)
                .map { path in localRoot.appendingPathComponent(Self.relativeRemotePath(path, root: remoteRoot), isDirectory: true) }
            let fileEntries = parts[1]
                .split(separator: "\n")
                .map(String.init)
                .map { path in
                    RemoteDownloadEntry(
                        remotePath: path,
                        localURL: localRoot.appendingPathComponent(Self.relativeRemotePath(path, root: remoteRoot))
                    )
                }

            completion(.success((directoryURLs.isEmpty ? [localRoot] : directoryURLs, fileEntries)))
        }
    }

    private static func relativeRemotePath(_ path: String, root: String) -> String {
        var normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        if normalizedRoot == "." || normalizedRoot == "~" {
            normalizedRoot = ""
        }
        guard !normalizedRoot.isEmpty, path.hasPrefix(normalizedRoot) else {
            return (path as NSString).lastPathComponent
        }
        var suffix = String(path.dropFirst(normalizedRoot.count))
        if suffix.hasPrefix("/") {
            suffix.removeFirst()
        }
        return suffix
    }

    private func createLocalDirectories(_ urls: [URL]) throws {
        for url in Set(urls.map(\.path)).map(URL.init(fileURLWithPath:)) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func downloadExpandedFiles(_ files: [RemoteDownloadEntry], item: TransferItem,
                                       session: Session,
                                       completion: (@MainActor (Bool) -> Void)?) {
        do {
            for file in files {
                try FileManager.default.createDirectory(
                    at: file.localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
        } catch {
            item.status = .failed("Could not create local folder: \(error.localizedDescription)")
            completion?(false)
            return
        }

        let commands = files.map {
            "get -a \(Self.sftpRemotePath($0.remotePath)) \(Self.sftpLocalPath($0.localURL.path))"
        }
        sftpTransfer(commands: commands, session: session, item: item, isDirectory: true, completion: completion)
    }

    private func invalidateCache(for path: String) {
        guard let profileID = session?.id else { return }
        dirCache.invalidate(profileID: profileID, path: Self.normalizedRemotePath(path))
    }

    private func scheduleRefreshAfterMutation(path: String) {
        invalidateCache(for: path)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.listFiles(at: self?.currentPath ?? path, pushHistory: false, forceRefresh: true)
            }
        }
    }

    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        dirCache.removeAll()
        listFiles(at: currentPath, pushHistory: false, forceRefresh: true)
    }

    func copyFile(_ file: RemoteFile, to newName: String, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        let srcPath = Self.childPath(parent: currentPath, child: file.name)
        let dstPath = Self.childPath(parent: currentPath, child: newName)
        let flag = file.isDirectory ? "-r " : ""
        runSSH(session: session, command: "cp \(flag)-- \(SSHSecurity.remoteShellPath(srcPath)) \(SSHSecurity.remoteShellPath(dstPath))") { [weak self] _ in
            self?.scheduleRefreshAfterMutation(path: self?.currentPath ?? ".")
            completion?()
        }
    }

    func moveClipboardItemsSameServer(
        _ items: [SFTPClipboardItem],
        to destinationPath: String,
        session: Session,
        overwrite: Bool = false,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        guard !items.isEmpty else {
            completion?(true)
            return
        }
        guard self.session?.id == session.id else {
            error = "Move is only available within the same SFTP profile."
            completion?(false)
            return
        }

        let itemName = items.count == 1 ? items[0].name : "\(items.count) items"
        let transferItem = TransferItem(name: itemName, direction: .serverToServer)
        transferItem.profileLabel = "SFTP move"
        TransferQueue.shared.add(transferItem)

        let commands: [String]
        do {
            commands = try SFTPMutationBatchBuilder.renameCommands(
                items: items,
                destinationPath: destinationPath,
                overwrite: overwrite
            )
        } catch {
            transferItem.status = .failed(error.localizedDescription)
            self.error = error.localizedDescription
            completion?(false)
            return
        }

        transferItem.status = .inProgress
        transferItem.startedAt = Date()
        sftpTransfer(commands: commands, session: session, item: transferItem, isDirectory: items.contains(where: \.isDirectory)) { [weak self] succeeded in
            guard let self else {
                completion?(false)
                return
            }
            if succeeded {
                transferItem.status = .completed
                transferItem.percentDone = 100
                self.error = nil
                let sourceParents = Set(items.compactMap { Self.remoteParentPath($0.path) })
                sourceParents.forEach { self.invalidateCache(for: $0) }
                self.invalidateCache(for: destinationPath)
                self.listFiles(at: self.currentPath, pushHistory: false, forceRefresh: true)
                ConnectionLog.shared.log(
                    "Moved \(itemName) to \(destinationPath)",
                    level: .success,
                    session: session.name
                )
            } else if case .failed(let message) = transferItem.status {
                self.error = "Move failed: \(message)"
            }
            completion?(succeeded)
        }
    }

    func downloadMany(files: [RemoteFile], to localURL: URL, session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard !files.isEmpty else { completion?(); return }
        let items = files.map { file in
            (
                remotePath: Self.childPath(parent: currentPath, child: file.name),
                name: file.name,
                isDirectory: file.isDirectory
            )
        }
        downloadBatch(remoteItems: items, to: localURL, session: session, completion: completion)
    }

    func downloadBatch(
        remoteItems: [(remotePath: String, name: String, isDirectory: Bool)],
        to localURL: URL,
        session: Session,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard !remoteItems.isEmpty else { completion?(); return }
        guard let session = self.session else { return }

        let itemName = remoteItems.count == 1 ? remoteItems[0].name : "\(remoteItems.count) items"
        let item = TransferItem(name: itemName, direction: .download)
        item.profileLabel = "Fast SFTP batch"
        TransferQueue.shared.add(item)

        let directories = remoteItems.filter(\.isDirectory)
        guard directories.isEmpty else {
            expandAndDownloadRemoteItems(
                remoteItems: remoteItems,
                to: localURL,
                session: session,
                item: item,
                completion: completion
            )
            return
        }

        let commands = remoteItems.map { remoteItem -> String in
            let destination = localURL.appendingPathComponent(remoteItem.name).path
            return "get -a \(Self.sftpRemotePath(remoteItem.remotePath)) \(Self.sftpLocalPath(destination))"
        }

        sftpTransfer(commands: commands, session: session, item: item, isDirectory: remoteItems.contains(where: \.isDirectory)) { succeeded in
            if succeeded {
                item.status = .completed
                item.percentDone = 100
                ConnectionLog.shared.log(
                    "Downloaded \(remoteItems.count) item\(remoteItems.count == 1 ? "" : "s") to \(localURL.path)",
                    level: .success,
                    session: session.name
                )
            }
            completion?()
        }
    }

    func rename(file: RemoteFile, to newName: String, session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        let oldPath = Self.childPath(parent: currentPath, child: file.name)
        let newPath = Self.childPath(parent: currentPath, child: newName)
        runSSH(session: session, command: "mv -- \(SSHSecurity.remoteShellPath(oldPath)) \(SSHSecurity.remoteShellPath(newPath))") { [weak self] _ in
            self?.invalidateCache(for: self?.currentPath ?? ".")
            self?.listFiles(at: self?.currentPath ?? ".", pushHistory: false)
            completion?()
        }
    }

    @Published var isDeleting = false
    @Published var deleteProgress: String = ""

    func delete(file: RemoteFile, session: Session, completion: (@MainActor () -> Void)? = nil) {
        deleteMany(files: [file], completion: completion)
    }

    func deleteMany(files: [RemoteFile], completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session, !files.isEmpty else { return }
        isDeleting = true
        deleteProgress = "Deleting \(files.count) item\(files.count == 1 ? "" : "s")…"

        // Build one command: rm -rf for dirs, rm for files, all in a single SSH call
        let parts = files.map { f -> String in
            let path = Self.childPath(parent: currentPath, child: f.name)
            return "rm -rf -- \(SSHSecurity.remoteShellPath(path))"
        }
        let marker = "__SSHCLIENT_DELETE_OK__"
        let cmd = parts.joined(separator: " && ") + " && printf '\(marker)'"

        runSSH(session: session, command: cmd) { [weak self] output in
            self?.isDeleting = false
            self?.deleteProgress = ""
            if output?.contains(marker) == true {
                self?.error = nil
                self?.scheduleRefreshAfterMutation(path: self?.currentPath ?? ".")
                completion?()
            } else {
                let detail = output?.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.error = detail?.isEmpty == false ? "Delete failed: \(detail!)" : "Delete failed"
            }
        }
    }

    func newFolder(named name: String, session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        runSSH(session: session, command: "mkdir -p -- \(SSHSecurity.remoteShellPath(Self.childPath(parent: currentPath, child: name)))") { [weak self] _ in
                self?.scheduleRefreshAfterMutation(path: self?.currentPath ?? ".")
                completion?()
        }
    }

    func newFile(named name: String, session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        runSSH(session: session, command: "touch -- \(SSHSecurity.remoteShellPath(Self.childPath(parent: currentPath, child: name)))") { [weak self] _ in
            self?.scheduleRefreshAfterMutation(path: self?.currentPath ?? ".")
            completion?()
        }
    }

    func changePermissions(file: RemoteFile, mode: String, session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        guard mode.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil else {
            error = "Invalid permission mode"
            return
        }
        runSSH(session: session, command: "chmod \(mode) -- \(SSHSecurity.remoteShellPath(Self.childPath(parent: currentPath, child: file.name)))") { [weak self] _ in
            self?.scheduleRefreshAfterMutation(path: self?.currentPath ?? ".")
            completion?()
        }
    }

    // Re-uploads a locally-edited temp file back to its original remote path.
    func uploadBack(localURL: URL, remotePath: String, completion: (@MainActor () -> Void)? = nil) {
        guard let activeSession = self.session else {
            ConnectionLog.shared.log("uploadBack: no active session", level: .error, session: "?")
            completion?()
            return
        }
        let item = TransferItem(name: localURL.lastPathComponent, direction: .upload)
        item.profileLabel = "Saving to server…"
        TransferQueue.shared.add(item)
        let parentPath = Self.remoteParentPath(remotePath) ?? currentPath
        let stagedName = ".\(localURL.lastPathComponent).sshstudio-upload-\(UUID().uuidString)"
        let stagedPath = Self.childPath(parent: parentPath, child: stagedName)
        ensureRemoteDirectory(at: parentPath, session: activeSession) { [weak self] ensured in
            guard let self, ensured else {
                item.status = .failed("Could not reach remote directory")
                completion?()
                return
            }
            self.sftpTransfer(
                command: "put -a \(Self.sftpLocalPath(localURL.path)) \(Self.sftpRemotePath(stagedPath))",
                session: activeSession,
                item: item,
                isDirectory: false
            ) { [weak self] succeeded in
                guard let self, succeeded else { completion?(); return }
                self.finishUpload(
                    localName: localURL.lastPathComponent,
                    stagedPath: stagedPath,
                    remotePath: remotePath,
                    session: activeSession,
                    item: item,
                    completion: completion
                )
            } fallback: { [weak self] in
                guard let self else { return }
                self.rsyncTransfer(
                    from: localURL.path,
                    to: self.remoteLocation(session: activeSession, path: stagedPath),
                    session: activeSession,
                    item: item,
                    completeOnSuccess: false,
                    isDirectory: false
                ) { [weak self] succeeded in
                    guard let self, succeeded else { completion?(); return }
                    self.finishUpload(
                        localName: localURL.lastPathComponent,
                        stagedPath: stagedPath,
                        remotePath: remotePath,
                        session: activeSession,
                        item: item,
                        completion: completion
                    )
                }
            }
        }
    }

    func upload(localURL: URL, session: Session, completion: (@MainActor () -> Void)? = nil) {
        guard let session = self.session else { return }
        let isDirectory = (try? localURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            uploadDirectoryTree(localURL: localURL, session: session, completion: completion)
            return
        }

        let remotePath = Self.childPath(parent: currentPath, child: localURL.lastPathComponent)
        let item = TransferItem(name: localURL.lastPathComponent, direction: .upload)
        TransferQueue.shared.add(item)
        uploadSingleFile(localURL: localURL, remotePath: remotePath, session: session, item: item, completion: completion)
    }

    private func uploadDirectoryTree(localURL: URL, session: Session, completion: (@MainActor () -> Void)? = nil) {
        let remoteRootPath = Self.childPath(parent: currentPath, child: localURL.lastPathComponent)
        let item = TransferItem(name: localURL.lastPathComponent, direction: .upload)
        item.profileLabel = "Fast folder upload"
        TransferQueue.shared.add(item)

        item.addDetailLine("Local: \(localURL.path)")
        item.addDetailLine("Remote: \(remoteRootPath)")

        ensureWritableRemoteDirectory(at: currentPath, session: session) { [weak self] ensured in
            guard let self else {
                completion?()
                return
            }
            guard ensured else {
                item.status = .failed("Remote directory is not writable: \(self.currentPath)")
                item.addDetailLine("Open a writable folder for this profile and try again.")
                completion?()
                return
            }

            self.rsyncTransfer(
                from: localURL.path,
                to: self.remoteLocation(session: session, path: self.currentPath),
                session: session,
                item: item,
                completeOnSuccess: true,
                isDirectory: true
            ) { [weak self] succeeded in
                guard let self else {
                    completion?()
                    return
                }
                if succeeded {
                    self.scheduleRefreshAfterMutation(path: self.currentPath)
                    ConnectionLog.shared.log(
                        "Uploaded folder \(localURL.lastPathComponent) to \(remoteRootPath)\(Self.transferSizeSuffix(for: item))",
                        level: .success,
                        session: session.name
                    )
                    completion?()
                    return
                }

                ConnectionLog.shared.log(
                    "Fast folder upload failed for \(localURL.lastPathComponent); retrying with SFTP",
                    level: .warning,
                    session: session.name
                )
                self.uploadDirectoryTreeWithSFTP(
                    localURL: localURL,
                    remoteRootPath: remoteRootPath,
                    session: session,
                    item: item,
                    completion: completion
                )
            }
        }
    }

    private func uploadDirectoryTreeWithSFTP(localURL: URL, remoteRootPath: String, session: Session,
                                             item: TransferItem,
                                             completion: (@MainActor () -> Void)? = nil) {
        let entriesToCreate = collectUploadEntries(in: localURL)
        let directories = entriesToCreate.directories.map {
            Self.joinRemotePath(remoteRootPath, relativeUploadPath(for: $0, root: localURL))
        }
        let files = entriesToCreate.files

        createRemoteDirectories([remoteRootPath] + directories, session: session) { created in
            guard created else {
                completion?()
                return
            }

            item.profileLabel = "Fast SFTP folder upload"

            guard !files.isEmpty else {
                item.status = .completed
                item.percentDone = 100
                ConnectionLog.shared.log(
                    "Created remote folder \(remoteRootPath)",
                    level: .success,
                    session: session.name
                )
                completion?()
                return
            }

            self.filterCompletedUploadFiles(files, localRoot: localURL, remoteRootPath: remoteRootPath, session: session, item: item) { filesToTransfer in
                guard !filesToTransfer.isEmpty else {
                    item.status = .completed
                    item.percentDone = 100
                    ConnectionLog.shared.log(
                        "Skipped upload for \(localURL.lastPathComponent); all files already exist at \(remoteRootPath)",
                        level: .success,
                        session: session.name
                    )
                    completion?()
                    return
                }

                let commands = filesToTransfer.map { fileURL -> String in
                    let relativePath = self.relativeUploadPath(for: fileURL, root: localURL)
                    let remotePath = Self.joinRemotePath(remoteRootPath, relativePath)
                    return "put -a \(Self.sftpLocalPath(fileURL.path)) \(Self.sftpRemotePath(remotePath))"
                }

                self.sftpTransfer(commands: commands, session: session, item: item, isDirectory: true) { succeeded in
                    if succeeded {
                        item.status = .completed
                        item.percentDone = 100
                        ConnectionLog.shared.log(
                            "Uploaded folder \(localURL.lastPathComponent) to \(remoteRootPath)",
                            level: .success,
                            session: session.name
                        )
                    }
                    completion?()
                }
            }
        }
    }

    private func uploadSingleFile(localURL: URL, remotePath: String, session: Session,
                                  item: TransferItem, completion: (@MainActor () -> Void)? = nil) {
        item.status = .inProgress
        item.startedAt = Date()
        item.profileLabel = "SFTP transfer"
        item.addDetailLine("Local: \(localURL.path)")
        item.addDetailLine("Remote: \(remotePath)")

        guard FileManager.default.fileExists(atPath: localURL.path) else {
            item.status = .failed("Local file does not exist: \(localURL.path)")
            completion?()
            return
        }

        let parentPath = Self.remoteParentPath(remotePath) ?? currentPath
        ensureWritableRemoteDirectory(at: parentPath, session: session) { [weak self] ensured in
            guard let self else { return }
            guard ensured else {
                item.status = .failed("Remote directory is not writable: \(parentPath)")
                item.addDetailLine("Open a writable folder for this profile and try again.")
                completion?()
                return
            }
            self.skipIfRemoteFileIsComplete(localURL: localURL, remotePath: remotePath, session: session, item: item) { [weak self] shouldSkip in
                guard let self else { return }
                guard !shouldSkip else {
                    self.finishFastUpload(
                        localName: localURL.lastPathComponent,
                        remotePath: remotePath,
                        session: session,
                        item: item,
                        completion: completion
                    )
                    return
                }

                self._uploadSingleFileSubprocess(
                    localURL: localURL, remotePath: remotePath,
                    session: session, item: item, completion: completion
                )
            }
        }
    }

    private func _uploadSingleFileSubprocess(localURL: URL, remotePath: String, session: Session,
                                             item: TransferItem, completion: (@MainActor () -> Void)? = nil) {
        let parentPath = Self.remoteParentPath(remotePath) ?? currentPath
        ensureWritableRemoteDirectory(at: parentPath, session: session) { [weak self] ensured in
            guard let self else { return }
            guard ensured else {
                item.status = .failed("Remote directory is not writable: \(parentPath)")
                item.addDetailLine("Open a writable folder for this profile and try again.")
                completion?()
                return
            }

            self.sftpTransfer(
                command: "put -a \(Self.sftpLocalPath(localURL.path)) \(Self.sftpRemotePath(remotePath))",
                session: session,
                item: item,
                isDirectory: false
            ) { [weak self] succeeded in
                guard let self else { return }
                guard succeeded else {
                    completion?()
                    return
                }
                self.finishFastUpload(
                    localName: localURL.lastPathComponent,
                    remotePath: remotePath,
                    session: session,
                    item: item,
                    completion: completion
                )
            } fallback: { [weak self] in
                guard let self else { return }
                ConnectionLog.shared.log(
                    "SFTP upload failed for \(localURL.lastPathComponent); retrying with rsync",
                    level: .warning, session: session.name
                )
                self.rsyncTransfer(
                    from: localURL.path,
                    to: self.remoteLocation(session: session, path: remotePath),
                    session: session,
                    item: item,
                    completeOnSuccess: true,
                    isDirectory: false
                ) { succeeded in
                    if succeeded {
                        ConnectionLog.shared.log(
                            "Uploaded \(localURL.lastPathComponent) to \(remotePath)\(Self.transferSizeSuffix(for: item))",
                            level: .success,
                            session: session.name
                        )
                    }
                    completion?()
                }
            }
        }
    }

    private func ensureRemoteDirectory(at path: String, session: Session,
                                       completion: @escaping @MainActor (Bool) -> Void) {
        guard path != ".", path != "~", !path.isEmpty else {
            completion(true)
            return
        }
        runSSHWithStatus(session: session, command: "mkdir -p -- \(SSHSecurity.remoteShellPath(path))") { status, _ in
            completion(status == 0)
        }
    }

    private func ensureWritableRemoteDirectory(at path: String, session: Session,
                                               completion: @escaping @MainActor (Bool) -> Void) {
        guard path != ".", path != "~", !path.isEmpty else {
            completion(true)
            return
        }
        let quotedPath = SSHSecurity.remoteShellPath(path)
        runSSHWithStatus(session: session, command: "mkdir -p -- \(quotedPath) && [ -w \(quotedPath) ]") { status, output in
            if status != 0 {
                let detail = output?.trimmingCharacters(in: .whitespacesAndNewlines)
                ConnectionLog.shared.log(
                    detail?.isEmpty == false ? "Remote directory is not writable: \(path): \(detail!)" : "Remote directory is not writable: \(path)",
                    level: .error,
                    session: session.name
                )
            }
            completion(status == 0)
        }
    }

    private func collectUploadEntries(in root: URL) -> (directories: [URL], files: [URL]) {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return ([], []) }

        var directories: [URL] = []
        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                directories.append(url)
            } else {
                files.append(url)
            }
        }
        return (
            directories.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }

    private func skipIfRemoteFileIsComplete(localURL: URL, remotePath: String, session: Session,
                                            item: TransferItem,
                                            completion: @escaping @MainActor (Bool) -> Void) {
        guard let localSize = Self.localFileSize(localURL) else {
            completion(false)
            return
        }

        remoteFileSizes(paths: [remotePath], session: session) { sizes in
            let isComplete = sizes[remotePath] == localSize
            if isComplete {
                item.totalBytes = max(item.totalBytes, localSize)
                item.bytesTransferred = max(item.bytesTransferred, localSize)
                item.addDetailLine("Skipped complete remote file: \(remotePath)")
            }
            completion(isComplete)
        }
    }

    private func filterCompletedUploadFiles(_ files: [URL], localRoot: URL, remoteRootPath: String,
                                            session: Session, item: TransferItem,
                                            completion: @escaping @MainActor ([URL]) -> Void) {
        let pairs = files.map { fileURL -> (localURL: URL, remotePath: String, localSize: Int64?) in
            let relativePath = self.relativeUploadPath(for: fileURL, root: localRoot)
            return (
                localURL: fileURL,
                remotePath: Self.joinRemotePath(remoteRootPath, relativePath),
                localSize: Self.localFileSize(fileURL)
            )
        }

        remoteFileSizes(paths: pairs.map(\.remotePath), session: session) { remoteSizes in
            var skippedCount = 0
            var skippedBytes: Int64 = 0
            let remaining = pairs.compactMap { pair -> URL? in
                guard let localSize = pair.localSize else { return pair.localURL }
                if remoteSizes[pair.remotePath] == localSize {
                    skippedCount += 1
                    skippedBytes += localSize
                    return nil
                }
                return pair.localURL
            }

            if skippedCount > 0 {
                item.bytesTransferred = max(item.bytesTransferred, skippedBytes)
                item.addDetailLine("Skipped \(skippedCount) complete file\(skippedCount == 1 ? "" : "s")")
                ConnectionLog.shared.log(
                    "Skipping \(skippedCount) already-complete file\(skippedCount == 1 ? "" : "s") before SFTP upload",
                    level: .info,
                    session: session.name
                )
            }
            completion(remaining)
        }
    }

    private func remoteFileSizes(paths: [String], session: Session,
                                 completion: @escaping @MainActor ([String: Int64]) -> Void) {
        let uniquePaths = Array(Set(paths)).sorted()
        guard !uniquePaths.isEmpty else {
            completion([:])
            return
        }

        let batches = uniquePaths.chunked(into: 150)
        var sizes: [String: Int64] = [:]

        func runBatch(_ index: Int) {
            guard index < batches.count else {
                completion(sizes)
                return
            }

            let marker = "__SSHSTUDIO_SIZE__"
            let commands = batches[index].map { path -> String in
                let quoted = SSHSecurity.remoteShellPath(path)
                return "printf '\\(marker)\\t%s\\t' \(quoted); { stat -c %s -- \(quoted) 2>/dev/null || stat -f %z -- \(quoted) 2>/dev/null || printf -- -1; }; printf '\\n'"
            }

            runSSHWithStatus(session: session, command: commands.joined(separator: " ; ")) { status, output in
                guard status == 0, let output else {
                    completion(sizes)
                    return
                }

                for line in output.components(separatedBy: .newlines) where line.hasPrefix(marker + "\t") {
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count == 3, let size = Int64(parts[2]), size >= 0 else { continue }
                    sizes[parts[1]] = size
                }
                runBatch(index + 1)
            }
        }

        runBatch(0)
    }

    private static func localFileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }
        return values.fileSize.map(Int64.init)
    }

    private func createRemoteDirectories(_ paths: [String], session: Session,
                                         completion: @escaping @MainActor (Bool) -> Void) {
        let uniquePaths = Array(Set(paths))
            .filter { !$0.isEmpty && $0 != "." && $0 != "~" }
            .sorted { $0.count < $1.count }
        guard !uniquePaths.isEmpty else {
            completion(true)
            return
        }

        let mkdirCommands = uniquePaths.map {
            "mkdir -p -- \(SSHSecurity.remoteShellPath($0))"
        }
        runSSHWithStatus(session: session, command: mkdirCommands.joined(separator: " && ")) { status, output in
            if status != 0 {
                let detail = output?.trimmingCharacters(in: .whitespacesAndNewlines)
                ConnectionLog.shared.log(
                    detail?.isEmpty == false ? "Could not create remote directories: \(detail!)" : "Could not create remote directories",
                    level: .error,
                    session: session.name
                )
            }
            completion(status == 0)
        }
    }

    private func relativeUploadPath(for fileURL: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return fileURL.lastPathComponent }
        var suffix = String(filePath.dropFirst(rootPath.count))
        if suffix.hasPrefix("/") {
            suffix.removeFirst()
        }
        return suffix.isEmpty ? fileURL.lastPathComponent : suffix
    }

    private static func joinRemotePath(_ base: String, _ relative: String) -> String {
        guard !relative.isEmpty else { return base }
        if base == "~" || base == "/" || base == "." {
            return "\(base)/\(relative)"
        }
        return base.hasSuffix("/") ? "\(base)\(relative)" : "\(base)/\(relative)"
    }

    private static func remoteParentPath(_ path: String) -> String? {
        guard path != "~", path != "/", path != ".", !path.isEmpty else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    private func finishFastUpload(localName: String, remotePath: String,
                                  session: Session, item: TransferItem,
                                  completion: (@MainActor () -> Void)?) {
        item.status = .completed
        item.percentDone = 100
        item.bytesTransferred = max(item.bytesTransferred, item.totalBytes)
        ConnectionLog.shared.log(
            "Uploaded \(localName) to \(remotePath)\(Self.transferSizeSuffix(for: item))",
            level: .success,
            session: session.name
        )
        completion?()
    }

    private func finishUpload(localName: String, stagedPath: String, remotePath: String,
                              session: Session, item: TransferItem,
                              completion: (@MainActor () -> Void)?) {
        let target = SSHSecurity.remoteShellPath(remotePath)
        let staged = SSHSecurity.remoteShellPath(stagedPath)
        let marker = "__SSHCLIENT_UPLOAD_REPLACED__"
        runSSH(
            session: session,
            command: "rm -rf \(target) && mv \(staged) \(target) && printf '\(marker)'"
        ) { output in
            if output?.contains(marker) == true {
                item.status = .completed
                item.percentDone = 100
                item.bytesTransferred = max(item.bytesTransferred, item.totalBytes)
                ConnectionLog.shared.log(
                    "Uploaded \(localName) to \(remotePath)\(Self.transferSizeSuffix(for: item))",
                    level: .success,
                    session: session.name
                )
                completion?()
            } else {
                let detail = output?.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = detail?.isEmpty == false
                    ? "Uploaded, but could not replace the existing remote item: \(detail!)"
                    : "Uploaded, but could not replace the existing remote item"
                item.status = .failed(message)
                ConnectionLog.shared.log("Upload failed for \(localName): \(message)", level: .error, session: session.name)
            }
        }
    }

    func copyRemoteToRemote(remotePath: String, name: String, isDirectory: Bool,
                            sourceSession: Session, destinationSession: Session,
                            destinationPath: String,
                            completion: (@MainActor (Bool) -> Void)? = nil) {
        let targetPath = Self.childPath(parent: destinationPath, child: name)
        let item = TransferItem(name: name, direction: .serverToServer)
        TransferQueue.shared.add(item)

        do {
            try SSHSecurity.validateNonInteractive(session: sourceSession, purpose: "Server-to-server transfers")
            try SSHSecurity.validateNonInteractive(session: destinationSession, purpose: "Server-to-server transfers")
        } catch {
            item.status = .failed(error.localizedDescription)
            completion?(false)
            return
        }

        item.profileLabel = "Server-to-server transfer"
        item.status = .inProgress
        item.startedAt = Date()
        ConnectionLog.shared.log(
            "Starting server-to-server transfer: \(sourceSession.name):\(remotePath) to \(destinationSession.name):\(targetPath)",
            level: .info,
            session: sourceSession.name
        )

        let parentPath = Self.remoteParentPath(targetPath) ?? "."
        ensureRemoteDirectory(at: parentPath, session: destinationSession) { [weak self] ensured in
            guard let self else {
                completion?(false)
                return
            }
            guard ensured else {
                item.addDetailLine("Could not create destination directory: \(parentPath)")
                self.copyRemoteToRemoteViaLocalRelay(
                    remotePath: remotePath,
                    name: name,
                    isDirectory: isDirectory,
                    sourceSession: sourceSession,
                    destinationSession: destinationSession,
                    targetPath: targetPath,
                    item: item,
                    completion: completion
                )
                return
            }

            let destination = self.remoteLocation(session: destinationSession, path: targetPath)
            let sshArgs = SSHSecurity.rsyncSSHArgs(for: destinationSession)
                .map(SSHSecurity.shellQuote)
                .joined(separator: " ")
            let profile = Self.transferProfile(for: name, isDirectory: isDirectory)
            let args = profile.rsyncArgs
                .map(SSHSecurity.shellQuote)
                .joined(separator: " ")
            let sourcePath = SSHSecurity.remoteShellPath(remotePath)
            let destinationPath = SSHSecurity.shellQuote(destination)
            let command = "rsync \(args) -e \(SSHSecurity.shellQuote(sshArgs)) \(sourcePath) \(destinationPath)"

            self.runSSHWithStatus(session: sourceSession, command: command) { exitStatus, output in
                if let output {
                    output.components(separatedBy: .newlines).forEach {
                        Self.recordRsyncEvent($0, into: item)
                    }
                }
                if exitStatus != 0 {
                    let message = output?
                        .components(separatedBy: .newlines)
                        .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                        ?? "Server-to-server rsync exited with status \(exitStatus)"
                    item.addDetailLine("Direct server-to-server rsync failed: \(message)")
                    ConnectionLog.shared.log(
                        "Direct server-to-server transfer failed for \(name); retrying through this Mac: \(message)",
                        level: .warning,
                        session: sourceSession.name
                    )
                    self.copyRemoteToRemoteViaLocalRelay(
                        remotePath: remotePath,
                        name: name,
                        isDirectory: isDirectory,
                        sourceSession: sourceSession,
                        destinationSession: destinationSession,
                        targetPath: targetPath,
                        item: item,
                        completion: completion
                    )
                } else {
                    item.status = .completed
                    item.percentDone = 100
                    item.bytesTransferred = max(item.bytesTransferred, item.totalBytes)
                    ConnectionLog.shared.log(
                        "Copied \(name) from \(sourceSession.name) to \(destinationSession.name):\(targetPath)\(Self.transferSizeSuffix(for: item))",
                        level: .success,
                        session: sourceSession.name
                    )
                    completion?(true)
                }
            }
        }
    }

    private func copyRemoteToRemoteViaLocalRelay(remotePath: String, name: String, isDirectory: Bool,
                                                 sourceSession: Session, destinationSession: Session,
                                                 targetPath: String, item: TransferItem,
                                                 completion: (@MainActor (Bool) -> Void)?) {
        let relayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-studio-relay-\(UUID().uuidString)", isDirectory: true)
        let relayURL = relayRoot.appendingPathComponent(name)

        do {
            try FileManager.default.createDirectory(at: relayRoot, withIntermediateDirectories: true)
        } catch {
            item.status = .failed("Could not create local relay folder: \(error.localizedDescription)")
            completion?(false)
            return
        }

        let cleanup: @MainActor () -> Void = {
            try? FileManager.default.removeItem(at: relayRoot)
        }
        let recursiveFlag = isDirectory ? " -r" : ""

        item.profileLabel = "Server-to-server via Mac"
        item.status = .inProgress
        item.addDetailLine("Retrying via local relay: \(relayURL.path)")

        sftpTransfer(
            command: "get -a\(recursiveFlag) \(Self.sftpRemotePath(remotePath)) \(Self.sftpLocalPath(relayURL.path))",
            session: sourceSession,
            item: item,
            isDirectory: isDirectory
        ) { [weak self] downloaded in
            guard let self else { cleanup(); completion?(false); return }
            guard downloaded else {
                cleanup()
                completion?(false)
                return
            }

            let parentPath = Self.remoteParentPath(targetPath) ?? "."
            let stagedName = ".\(name).sshstudio-relay-\(UUID().uuidString)"
            let stagedPath = Self.childPath(parent: parentPath, child: stagedName)

            self.ensureRemoteDirectory(at: parentPath, session: destinationSession) { ensured in
                guard ensured else {
                    cleanup()
                    item.status = .failed("Could not create destination directory")
                    completion?(false)
                    return
                }

                let uploadRelay: @MainActor () -> Void = {
                    let destination = self.remoteLocation(session: destinationSession, path: stagedPath)
                    self.rsyncTransfer(
                        from: relayURL.path,
                        to: destination,
                        session: destinationSession,
                        item: item,
                        completeOnSuccess: false,
                        isDirectory: isDirectory
                    ) { uploaded in
                        guard uploaded else {
                            cleanup()
                            completion?(false)
                            return
                        }

                        let target = SSHSecurity.remoteShellPath(targetPath)
                        let staged = SSHSecurity.remoteShellPath(stagedPath)
                        let marker = "__SSHCLIENT_RELAY_COPY_OK__"
                        self.runSSH(
                            session: destinationSession,
                            command: "rm -rf \(target) && mv \(staged) \(target) && printf '\(marker)'"
                        ) { output in
                            cleanup()
                            if output?.contains(marker) == true {
                                item.status = .completed
                                item.percentDone = 100
                                item.bytesTransferred = max(item.bytesTransferred, item.totalBytes)
                                ConnectionLog.shared.log(
                                    "Copied \(name) from \(sourceSession.name) to \(destinationSession.name):\(targetPath) through this Mac\(Self.transferSizeSuffix(for: item))",
                                    level: .success,
                                    session: sourceSession.name
                                )
                                completion?(true)
                            } else {
                                let detail = output?.trimmingCharacters(in: .whitespacesAndNewlines)
                                let message = detail?.isEmpty == false
                                    ? "Relay upload finished, but final rename failed: \(detail!)"
                                    : "Relay upload finished, but final rename failed"
                                item.status = .failed(message)
                                ConnectionLog.shared.log(
                                    "Server-to-server relay failed for \(name): \(message)",
                                    level: .error,
                                    session: sourceSession.name
                                )
                                completion?(false)
                            }
                        }
                    }
                }

                uploadRelay()
            }
        }
    }

    private func rsyncTarget(_ session: Session) -> String {
        SSHSecurity.rsyncTarget(for: session)
    }

    private func remoteLocation(session: Session, path: String) -> String {
        "\(rsyncTarget(session)):\(Self.rsyncRemotePath(path))"
    }

    private func sftpTransfer(commands: [String], session: Session,
                              item: TransferItem, isDirectory: Bool = false,
                              completion: (@MainActor (Bool) -> Void)?,
                              fallback: (@MainActor () -> Void)? = nil) {
        let batches = Self.sftpCommandBatches(from: commands)
        guard batches.count > 1 else {
            sftpTransfer(command: batches.first?.joined(separator: "\n") ?? "", session: session,
                         item: item, isDirectory: isDirectory, completion: completion, fallback: fallback)
            return
        }

        item.addDetailLine("Transferring \(commands.count) items in \(batches.count) SFTP batches")

        func runBatch(_ index: Int) {
            guard index < batches.count else {
                completion?(true)
                return
            }

            item.profileLabel = "SFTP batch \(index + 1)/\(batches.count)"
            sftpTransfer(command: batches[index].joined(separator: "\n"), session: session,
                         item: item, isDirectory: isDirectory) { succeeded in
                guard succeeded else {
                    fallback?()
                    completion?(false)
                    return
                }
                runBatch(index + 1)
            }
        }

        runBatch(0)
    }

    private func sftpTransfer(command: String, session: Session,
                              item: TransferItem, isDirectory: Bool = false,
                              completion: (@MainActor (Bool) -> Void)?,
                              fallback: (@MainActor () -> Void)? = nil) {
        do {
            try SSHSecurity.validateNonInteractive(session: session, purpose: Self.transferTitle(for: item.direction))
        } catch {
            item.status = .failed(error.localizedDescription)
            ConnectionLog.shared.log(
                "\(Self.transferTitle(for: item.direction)) failed for \(item.name): \(error.localizedDescription)",
                level: .error,
                session: session.name
            )
            fallback?()
            completion?(false)
            return
        }

        let batchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssh-studio-sftp-\(UUID().uuidString).batch")
        do {
            try (command + "\n").write(to: batchURL, atomically: true, encoding: .utf8)
        } catch {
            item.status = .failed(error.localizedDescription)
            ConnectionLog.shared.log(
                "\(Self.transferTitle(for: item.direction)) failed for \(item.name): \(error.localizedDescription)",
                level: .error,
                session: session.name
            )
            fallback?()
            completion?(false)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = Self.sftpArguments(for: session, batchURL: batchURL)
        item.attach(process)

        let pipe = Pipe()
        let reader = PipeReader(pipe: pipe)
        let output = RsyncOutputBuffer()
        process.standardOutput = pipe
        process.standardError = pipe

        item.profileLabel = isDirectory ? "SFTP folder transfer" : "SFTP transfer"
        item.status = .inProgress
        item.startedAt = Date()
        ConnectionLog.shared.log(
            "Starting \(Self.transferAction(for: item.direction)): \(item.name)",
            level: .info,
            session: session.name
        )

        process.terminationHandler = { @Sendable p in
            _ = reader.waitUntilFinished(timeout: 1)
            let remainingLines = output.finish()
            try? FileManager.default.removeItem(at: batchURL)
            Task { @MainActor in
                remainingLines.forEach {
                    SFTPManager.parseRsyncLine($0, into: item)
                    SFTPManager.recordSFTPEvent($0, into: item, session: session)
                    if let detail = SFTPManager.sftpTransferDetail(from: $0) {
                        item.addDetailLine(detail)
                    }
                }
                item.clearProcess()
                if let cancellationStatus = item.finishCancellationIfNeeded() {
                    item.status = cancellationStatus
                    completion?(false)
                    return
                }
                if p.terminationStatus == 0 {
                    completion?(true)
                } else {
                    let message = output.failureDescription(exitStatus: p.terminationStatus)
                    item.status = .failed(message)
                    ConnectionLog.shared.log(
                        "\(Self.transferTitle(for: item.direction)) failed for \(item.name): \(message)",
                        level: .error,
                        session: session.name
                    )
                    if let fallback {
                        fallback()
                    } else {
                        completion?(false)
                    }
                }
            }
        }

        Task { @MainActor in
            switch await HostKeyVerificationGate.allowConnection(session: session) {
            case .success:
                do {
                    try process.run()
                    Task {
                        await SFTPPerformanceRecorder.shared.recordProcessLaunch()
                    }
                    reader.start { data in
                        for line in output.consume(data) {
                            Task { @MainActor in
                                SFTPManager.parseRsyncLine(line, into: item)
                                SFTPManager.recordSFTPEvent(line, into: item, session: session)
                                if let detail = SFTPManager.sftpTransferDetail(from: line) {
                                    item.addDetailLine(detail)
                                }
                            }
                        }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: batchURL)
                    item.status = .failed(error.localizedDescription)
                    ConnectionLog.shared.log(
                        "\(Self.transferTitle(for: item.direction)) failed for \(item.name): \(error.localizedDescription)",
                        level: .error,
                        session: session.name
                    )
                    if let fallback {
                        fallback()
                    } else {
                        completion?(false)
                    }
                }
            case .failure(let error):
                try? FileManager.default.removeItem(at: batchURL)
                item.status = .failed(error.localizedDescription)
                completion?(false)
            }
        }
    }

    private func rsyncTransfer(from: String, to: String, session: Session,
                               item: TransferItem, completeOnSuccess: Bool = true,
                               isDirectory: Bool = false,
                               extraArgs: [String] = [],
                               completion: (@MainActor (Bool) -> Void)?) {
        do {
            try SSHSecurity.validateNonInteractive(session: session, purpose: Self.transferTitle(for: item.direction))
        } catch {
            item.status = .failed(error.localizedDescription)
            completion?(false)
            return
        }
        let sshCmd = SSHSecurity.rsyncSSHArgs(for: session)
            .map(SSHSecurity.shellQuote)
            .joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        let profile = Self.transferProfile(for: item.name, isDirectory: isDirectory)
        item.profileLabel = profile.label
        process.arguments = profile.rsyncArgs + extraArgs + ["-e", sshCmd, from, to]
        item.attach(process)

        let pipe = Pipe()
        let reader = PipeReader(pipe: pipe)
        let output = RsyncOutputBuffer()
        process.standardOutput = pipe
        process.standardError  = pipe

        item.status    = .inProgress
        item.startedAt = Date()

        process.terminationHandler = { @Sendable p in
            _ = reader.waitUntilFinished(timeout: 1)
            let remainingLines = output.finish()
            Task { @MainActor in
                remainingLines.forEach {
                    SFTPManager.recordRsyncEvent($0, into: item)
                }
                item.clearProcess()
                if let cancellationStatus = item.finishCancellationIfNeeded() {
                    item.status = cancellationStatus
                    completion?(false)
                    return
                }
                if p.terminationStatus == 0 {
                    if completeOnSuccess {
                        item.status      = .completed
                        item.percentDone = 100
                    }
                    completion?(true)
                } else {
                    item.status = .failed(output.failureDescription(exitStatus: p.terminationStatus))
                    completion?(false)
                }
            }
        }

        Task { @MainActor in
            switch await HostKeyVerificationGate.allowConnection(session: session) {
            case .success:
                do {
                    try process.run()
                    Task {
                        await SFTPPerformanceRecorder.shared.recordProcessLaunch()
                    }
                    reader.start { data in
                        for line in output.consume(data) {
                            Task { @MainActor in
                                SFTPManager.recordRsyncEvent(line, into: item)
                            }
                        }
                    }
                } catch {
                    item.status = .failed(error.localizedDescription)
                    item.clearProcess()
                    completion?(false)
                }
            case .failure(let error):
                item.status = .failed(error.localizedDescription)
                item.clearProcess()
                completion?(false)
            }
        }
    }

    // Parses rsync --progress output lines. For folders this is per-file progress,
    // while the detail list shows the filenames rsync is currently processing.
    // Progress: "    102,400  15%    1.23MB/s    0:00:05"
    // Stats:    "Total transferred file size: 1,234,567 bytes"
    static func parseRsyncLine(_ line: String, into item: TransferItem) {
        // Match: bytes  percent%  speed  eta
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 4,
           let pct = Double(parts[1].replacingOccurrences(of: "%", with: "")),
           pct >= 0, pct <= 100,
           parts[1].hasSuffix("%") {
            let bytes = Int64(parts[0].replacingOccurrences(of: ",", with: "")) ?? item.bytesTransferred
            item.applyProgress(
                bytesTransferred: bytes,
                percentDone: pct,
                speedBytesPerSec: parseSpeed(parts[2]),
                eta: parts[3]
            )
            return
        }
        // "Total transferred file size: 1,234,567 bytes"
        if line.contains("Total transferred file size:") {
            let digits = parts.compactMap { Int64($0.replacingOccurrences(of: ",", with: "")) }.first
            if let t = digits { item.totalBytes = t }
        }
    }

    static func recordRsyncEvent(_ line: String, into item: TransferItem) {
        parseRsyncLine(line, into: item)
        guard let detail = rsyncTransferDetail(from: line) else { return }
        item.profileLabel = detail
        item.addDetailLine(detail)
    }

    private static func rsyncTransferDetail(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 4, parts[1].hasSuffix("%") {
            return nil
        }

        let ignoredPrefixes = [
            "building file list",
            "created directory",
            "sent ",
            "total size is ",
            "Total transferred file size:",
            "Number of files:",
            "Number of files transferred:",
            "Total file size:",
            "Literal data:",
            "Matched data:",
            "File list size:",
            "File list generation time:",
            "File list transfer time:",
            "Total bytes sent:",
            "Total bytes received:"
        ]
        if ignoredPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return nil
        }

        let ignoredExact = ["./", "."]
        if ignoredExact.contains(trimmed) {
            return nil
        }

        return trimmed
    }

    static func recordSFTPEvent(_ line: String, into item: TransferItem, session: Session) {
        let event = sftpTransferEvent(from: line)
        guard let event else { return }

        item.profileLabel = event
        item.addDetailLine(event)
        ConnectionLog.shared.log(event, level: .info, session: session.name)
    }

    private static func sftpTransferDetail(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sftp>") { return nil }
        if let event = sftpTransferEvent(from: trimmed) { return event }

        let errorPrefixes = [
            "Couldn't ",
            "File ",
            "Permission denied",
            "stat ",
            "No such ",
            "not found",
            "Failure",
            "Connection closed",
            "Connection lost"
        ]
        if errorPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return trimmed
        }

        return nil
    }

    private static func parseSpeed(_ s: String) -> Double {
        let table: [(String, Double)] = [("GB/s",1e9),("MB/s",1e6),("kB/s",1e3),("B/s",1)]
        for (suf, mult) in table {
            if s.hasSuffix(suf), let v = Double(s.dropLast(suf.count)) { return v * mult }
        }
        return 0
    }

    private static func sftpTransferEvent(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("sftp>") {
            return nil
        }

        let ignoredPrefixes = [
            "Connected to ",
            "Changing to:",
            "Couldn't ",
            "File ",
            "Permission denied",
            "stat "
        ]
        if ignoredPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return nil
        }

        let eventPrefixes = [
            "Uploading ",
            "Downloading ",
            "Fetching ",
            "Sending ",
            "Retrieving ",
            "Entering ",
            "Creating directory ",
            "mkdir "
        ]
        if eventPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return trimmed
        }

        if trimmed.contains(" -> ") || trimmed.contains(" to ") {
            return trimmed
        }

        return nil
    }

    nonisolated static func resolvedPath(from output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "Remote working directory: "
                guard trimmed.hasPrefix(prefix) else { return nil }
                let path = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
            .last
    }

    private static func sftpArguments(for session: Session, batchURL: URL) -> [String] {
        (try? SSHCommandBuilder.sftpInvocation(for: session, batchURL: batchURL).arguments) ?? []
    }

    nonisolated private static func sftpLocalPath(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    nonisolated private static func sftpDirectoryCommands(for value: String) -> [String] {
        if value == "~" { return ["cd"] }
        if value.hasPrefix("~/") {
            return ["cd", "cd \(sftpLocalPath(String(value.dropFirst(2))))"]
        }
        return ["cd \(sftpLocalPath(value))"]
    }

    nonisolated private static func sftpRemotePath(_ value: String) -> String {
        if value == "~" { return "." }
        if value.hasPrefix("~/") {
            return sftpLocalPath(String(value.dropFirst(2)))
        }
        return sftpLocalPath(value)
    }

    private static func rsyncRemotePath(_ value: String) -> String {
        if value.isEmpty { return "." }

        let safeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-~")
        var escaped = ""
        for scalar in value.unicodeScalars {
            if safeCharacters.contains(scalar) {
                escaped.unicodeScalars.append(scalar)
            } else {
                escaped.append("\\")
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    private static func transferAction(for direction: TransferDirection) -> String {
        switch direction {
        case .upload: return "upload"
        case .download: return "download"
        case .serverToServer: return "server-to-server transfer"
        }
    }

    private static func transferTitle(for direction: TransferDirection) -> String {
        switch direction {
        case .upload: return "Upload"
        case .download: return "Download"
        case .serverToServer: return "Server-to-server transfer"
        }
    }

    private static func transferSizeSuffix(for item: TransferItem) -> String {
        let bytes = max(item.bytesTransferred, item.totalBytes)
        guard bytes > 0 else { return "" }
        return " (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))"
    }

    private static func sftpCommandBatches(from commands: [String]) -> [[String]] {
        let maxBatchBytes = 24_000
        var batches: [[String]] = []
        var current: [String] = []
        var currentBytes = 0

        for command in commands {
            let commandBytes = command.utf8.count + 1
            if !current.isEmpty, currentBytes + commandBytes > maxBatchBytes {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(command)
            currentBytes += commandBytes
        }

        if !current.isEmpty {
            batches.append(current)
        }
        return batches
    }

    nonisolated private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return "~" }
        do {
            return try SFTPPath(trimmed).rawValue
        } catch {
            return trimmed.replacingOccurrences(of: #"//+"#, with: "/", options: .regularExpression)
        }
    }

    private static func transferProfile(for name: String, isDirectory: Bool) -> (label: String, rsyncArgs: [String]) {
        let extensionName = (name as NSString).pathExtension.lowercased()
        let bulkExtensions: Set<String> = [
            "xtc", "trr", "dcd", "nc", "netcdf", "h5", "hdf5", "hdf",
            "gro", "pdb", "tpr", "edr", "cpt", "npy", "npz",
            "zip", "gz", "bz2", "xz", "7z", "tar", "tgz"
        ]
        let commonArgs = ["-a", "--partial", "--whole-file", "--stats"]
        if isDirectory {
            return ("Folder transfer", commonArgs + ["--progress", "--out-format=%n"])
        }
        if bulkExtensions.contains(extensionName) {
            return ("Bulk scientific transfer", commonArgs + ["--progress"])
        }
        return ("Fast transfer", commonArgs + ["--progress"])
    }

    private func runSSH(session: Session, command: String, completion: @escaping @MainActor (String?) -> Void) {
        runSSHWithStatus(session: session, command: command) { _, output in
            completion(output)
        }
    }

    private func runSSHWithStatus(session: Session, command: String) async -> (status: Int32, output: String?) {
        await withCheckedContinuation { continuation in
            runSSHWithStatus(session: session, command: command) { status, output in
                continuation.resume(returning: (status, output))
            }
        }
    }

    private func runSSHWithStatus(session: Session, command: String, completion: @escaping @MainActor (Int32, String?) -> Void) {
        let process = Process()
        let invocation: SSHInvocation

        do {
            invocation = try SSHCommandBuilder.remoteCommandInvocation(for: session, command: command, purpose: .sftp)
        } catch {
            completion(255, error.localizedDescription)
            return
        }
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments

        let pipe = Pipe()
        let reader = PipeReader(pipe: pipe)
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { @Sendable process in
            let data = reader.collectedData()
            let output = String(data: data, encoding: .utf8)
            Task { @MainActor in
                let c = completion
                c(process.terminationStatus, output)
            }
        }

        Task { @MainActor in
            switch await HostKeyVerificationGate.allowConnection(session: session) {
            case .success:
                do {
                    try process.run()
                    Task {
                        await SFTPPerformanceRecorder.shared.recordProcessLaunch()
                    }
                    reader.start()
                } catch {
                    completion(255, nil)
                }
            case .failure(let error):
                completion(255, error.localizedDescription)
            }
        }
    }

    nonisolated private static func parse(lsOutput: String) -> [RemoteFile] {
        (try? SFTPDirectoryParser.parseListing(lsOutput).map { entry in
            return RemoteFile(
                name: entry.name,
                isDirectory: entry.isDirectory,
                size: entry.size.map(String.init) ?? "",
                permissions: entry.permissions,
                modified: entry.modified,
                modifiedDate: entry.modifiedDate
            )
        }) ?? []
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private final class RsyncOutputBuffer: @unchecked Sendable {
    private static let maxMessageLength = 500

    private let lock = NSLock()
    private var bufferedText = ""
    private var recentMessages: [String] = []

    func consume(_ data: Data) -> [String] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        return lock.withLock {
            bufferedText += text
            let parts = bufferedText.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\r")))
            bufferedText = parts.last ?? ""
            return parts.dropLast().compactMap(record)
        }
    }

    func finish() -> [String] {
        lock.withLock {
            defer { bufferedText = "" }
            return record(bufferedText).map { [$0] } ?? []
        }
    }

    func failureDescription(exitStatus: Int32) -> String {
        lock.withLock {
            recentMessages.last ?? "rsync exited with status \(exitStatus)"
        }
    }

    private func record(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("sftp>") { return nil }
        let displayLine = Self.truncate(trimmed, limit: Self.maxMessageLength)
        if !trimmed.contains("%") {
            recentMessages.append(displayLine)
            recentMessages = Array(recentMessages.suffix(8))
        }
        return displayLine
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return "\(value.prefix(limit))... [truncated]"
    }
}
