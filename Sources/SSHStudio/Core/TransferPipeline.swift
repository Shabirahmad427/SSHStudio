import Foundation

enum TransferEndpoint: Equatable, Hashable, Sendable {
    case local
    case remote(profileID: UUID)
}

enum TransferItemType: String, Codable, Sendable {
    case file
    case directory
    case symlink
}

enum TransferOperation: String, Codable, Sendable {
    case copy
    case move
}

enum TransferConflictPolicy: Equatable, Sendable {
    case overwrite
    case merge
    case keepBoth
    case fail
    case cancel
}

enum TransferSymlinkPolicy: Equatable, Sendable {
    case preserve
    case follow
    case reject
}

struct TransferRequest: Equatable, Sendable {
    let sourceEndpoint: TransferEndpoint
    let destinationEndpoint: TransferEndpoint
    let itemType: TransferItemType
    let operation: TransferOperation
    let sourcePath: String
    let destinationDirectory: String
    let destinationName: String?
    let conflictPolicy: TransferConflictPolicy
    let symlinkPolicy: TransferSymlinkPolicy

    init(
        sourceEndpoint: TransferEndpoint,
        destinationEndpoint: TransferEndpoint,
        itemType: TransferItemType,
        operation: TransferOperation = .copy,
        sourcePath: String,
        destinationDirectory: String,
        destinationName: String? = nil,
        conflictPolicy: TransferConflictPolicy = .fail,
        symlinkPolicy: TransferSymlinkPolicy = .preserve
    ) {
        self.sourceEndpoint = sourceEndpoint
        self.destinationEndpoint = destinationEndpoint
        self.itemType = itemType
        self.operation = operation
        self.sourcePath = sourcePath
        self.destinationDirectory = destinationDirectory
        self.destinationName = destinationName
        self.conflictPolicy = conflictPolicy
        self.symlinkPolicy = symlinkPolicy
    }
}

enum TransferEngine: String, Codable, Sendable {
    case sftpGet
    case recursiveSFTPGet
    case rsyncGetFallback
    case sftpPut
    case recursiveSFTPPut
    case rsyncPutFallback
    case sftpRename
    case verifiedServerCopy
    case localRelay
    case localCopy
}

enum TransferCapability: String, Codable, Sendable {
    case sftp
    case recursiveSFTP
    case rsync
    case remoteRename
    case verifiedRemoteCopy
    case localStaging
    case localFilesystem
}

enum TransferCleanupPolicy: String, Codable, Sendable {
    case none
    case removePartialOnFailure
    case removeStagingAfterCompletion
    case preservePartialForResume
}

enum TransferFallbackPolicy: Equatable, Sendable {
    case none
    case capabilityOrTransportOnly(TransferEngine)
}

struct TransferPlan: Equatable, Sendable {
    let engine: TransferEngine
    let finalDestination: String
    let partialDestination: String?
    let requiredCapabilities: Set<TransferCapability>
    let cleanupPolicy: TransferCleanupPolicy
    let fallbackPolicy: TransferFallbackPolicy
}

enum TransferFailureCause: Error, Equatable, Sendable {
    case permissionDenied
    case readOnlyFilesystem
    case quotaExceeded
    case noSpace
    case missingParent
    case destinationExists
    case sourceMissing
    case connectionLost
    case authenticationFailed
    case hostKeyRejected
    case cancelled
    case unsupportedCapability
    case invalidPath
    case processFailure(String)
    case unknown(String)

    var title: String {
        switch self {
        case .permissionDenied: return "Permission denied"
        case .readOnlyFilesystem: return "Read-only filesystem"
        case .quotaExceeded: return "Quota exceeded"
        case .noSpace: return "No space left"
        case .missingParent: return "Missing parent directory"
        case .destinationExists: return "Destination exists"
        case .sourceMissing: return "Source not found"
        case .connectionLost: return "Connection lost"
        case .authenticationFailed: return "Authentication failed"
        case .hostKeyRejected: return "Host key rejected"
        case .cancelled: return "Cancelled"
        case .unsupportedCapability: return "Unsupported transfer capability"
        case .invalidPath: return "Invalid path"
        case .processFailure(let message), .unknown(let message): return message
        }
    }
}

enum TransferResult: Equatable, Sendable {
    case success
    case cancelled
    case partial
    case failed(TransferFailureCause)

    var description: String {
        switch self {
        case .success: return "Transfer completed"
        case .cancelled: return "Transfer cancelled"
        case .partial: return "Transfer partially completed"
        case .failed(let cause): return cause.title
        }
    }
}

enum TransferState: String, Codable, Sendable {
    case queued
    case validating
    case preparing
    case transferring
    case verifying
    case finalizing
    case completed
    case cancelled
    case partial
    case failed
}

enum TransferPlanner {
    static func plan(for request: TransferRequest) throws -> TransferPlan {
        guard !request.sourcePath.isEmpty, !request.destinationDirectory.isEmpty else {
            throw TransferFailureCause.invalidPath
        }
        guard request.symlinkPolicy != .reject || request.itemType != .symlink else {
            throw TransferFailureCause.unsupportedCapability
        }

        let final = try finalDestination(for: request)
        let partial = partialDestination(for: final, request: request)

        switch (request.sourceEndpoint, request.destinationEndpoint, request.operation) {
        case (.remote, .local, .move), (.local, .remote, .move):
            throw TransferFailureCause.unsupportedCapability
        case (.remote, .local, _):
            let engine: TransferEngine = request.itemType == .directory ? .recursiveSFTPGet : .sftpGet
            let fallback: TransferEngine = .rsyncGetFallback
            return TransferPlan(
                engine: engine,
                finalDestination: final,
                partialDestination: partial,
                requiredCapabilities: [request.itemType == .directory ? .recursiveSFTP : .sftp],
                cleanupPolicy: .removePartialOnFailure,
                fallbackPolicy: .capabilityOrTransportOnly(fallback)
            )
        case (.local, .remote, _):
            let engine: TransferEngine = request.itemType == .directory ? .recursiveSFTPPut : .sftpPut
            let fallback: TransferEngine = .rsyncPutFallback
            return TransferPlan(
                engine: engine,
                finalDestination: final,
                partialDestination: partial,
                requiredCapabilities: [request.itemType == .directory ? .recursiveSFTP : .sftp],
                cleanupPolicy: .removePartialOnFailure,
                fallbackPolicy: .capabilityOrTransportOnly(fallback)
            )
        case (.remote(let source), .remote(let destination), .move) where source == destination:
            return TransferPlan(engine: .sftpRename, finalDestination: final, partialDestination: nil,
                                requiredCapabilities: [.remoteRename], cleanupPolicy: .none, fallbackPolicy: .none)
        case (.remote(let source), .remote(let destination), .move) where source != destination:
            throw TransferFailureCause.unsupportedCapability
        case (.remote(let source), .remote(let destination), .copy) where source == destination:
            return TransferPlan(engine: .localRelay, finalDestination: final, partialDestination: partial,
                                requiredCapabilities: [.localStaging], cleanupPolicy: .removeStagingAfterCompletion,
                                fallbackPolicy: .none)
        case (.remote, .remote, _):
            return TransferPlan(engine: .localRelay, finalDestination: final, partialDestination: partial,
                                requiredCapabilities: [.localStaging], cleanupPolicy: .removeStagingAfterCompletion, fallbackPolicy: .none)
        case (.local, .local, .copy):
            return TransferPlan(engine: .localCopy, finalDestination: final, partialDestination: partial,
                                requiredCapabilities: [.localFilesystem], cleanupPolicy: .removePartialOnFailure, fallbackPolicy: .none)
        case (.local, .local, .move):
            throw TransferFailureCause.unsupportedCapability
        }
    }

    static func finalDestination(for request: TransferRequest) throws -> String {
        let name = request.destinationName ?? basename(of: request.sourcePath, endpoint: request.sourceEndpoint)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TransferFailureCause.invalidPath
        }
        if request.destinationEndpoint == .local {
            return URL(fileURLWithPath: request.destinationDirectory, isDirectory: true)
                .appendingPathComponent(name).path
        }
        return appendRemote(request.destinationDirectory, component: name)
    }

    static func basename(of path: String, endpoint: TransferEndpoint) -> String {
        if endpoint == .local { return URL(fileURLWithPath: path).lastPathComponent }
        let trimmed = path == "/" ? path : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func appendRemote(_ directory: String, component: String) -> String {
        if directory == "~" || directory == "/" { return "\(directory)/\(component)" }
        return directory.hasSuffix("/") ? "\(directory)\(component)" : "\(directory)/\(component)"
    }

    private static func partialDestination(for final: String, request: TransferRequest) -> String? {
        guard request.operation == .copy || request.destinationEndpoint != .local else { return nil }
        let suffix = ".sshstudio-partial-\(UUID().uuidString)"
        if request.destinationEndpoint == .local {
            let url = URL(fileURLWithPath: final)
            return url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)\(suffix)").path
        }
        let parts = final.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = parts.last else { return nil }
        let parent = parts.dropLast().joined(separator: "/")
        return "\(parent)/.\(last)\(suffix)"
    }
}

enum TransferFailureClassifier {
    static func classify(_ message: String, exitStatus: Int32? = nil) -> TransferFailureCause {
        let lower = message.lowercased()
        if lower.contains("host key") || lower.contains("man-in-the-middle") { return .hostKeyRejected }
        if lower.contains("permission denied") || lower.contains("operation not permitted") { return .permissionDenied }
        if lower.contains("read-only file system") || lower.contains("read only file system") { return .readOnlyFilesystem }
        if lower.contains("quota") { return .quotaExceeded }
        if lower.contains("no space left") || lower.contains("disk full") { return .noSpace }
        if lower.contains("no such file") || lower.contains("not found") { return .sourceMissing }
        if lower.contains("destination exists") || lower.contains("file exists") { return .destinationExists }
        if lower.contains("authentication") || lower.contains("publickey") { return .authenticationFailed }
        if lower.contains("connection closed") || lower.contains("connection reset") || lower.contains("broken pipe") || lower.contains("timed out") {
            return .connectionLost
        }
        if lower.contains("cancel") { return .cancelled }
        if let exitStatus { return .processFailure("Transfer process exited with status \(exitStatus): \(message)") }
        return .unknown(message.isEmpty ? "Transfer failed" : message)
    }
}

@MainActor
final class TransferService {
    static let shared = TransferService()

    @discardableResult
    func submit(
        _ request: TransferRequest,
        name: String,
        sourceSession: Session? = nil,
        destinationSession: Session? = nil,
        sourceManager: SFTPManager? = nil,
        destinationManager: SFTPManager? = nil,
        completion: (@MainActor (TransferResult) -> Void)? = nil
    ) -> TransferItem {
        let direction: TransferDirection
        switch (request.sourceEndpoint, request.destinationEndpoint) {
        case (.local, .remote): direction = .upload
        case (.remote, .local): direction = .download
        default: direction = .serverToServer
        }
        let item = TransferItem(name: name, direction: direction)
        TransferQueue.shared.add(item)
        item.retryHandler = { [weak self] in
            guard let self else { return }
            _ = self.submit(request, name: name, sourceSession: sourceSession,
                            destinationSession: destinationSession, sourceManager: sourceManager,
                            destinationManager: destinationManager, completion: completion)
        }

        do {
            let plan = try TransferPlanner.plan(for: request)
            item.apply(plan: plan)
            execute(request, plan: plan, item: item, sourceSession: sourceSession,
                    destinationSession: destinationSession, sourceManager: sourceManager,
                    destinationManager: destinationManager, completion: completion)
        } catch let cause as TransferFailureCause {
            item.fail(cause)
            completion?(.failed(cause))
        } catch {
            let cause = TransferFailureClassifier.classify(error.localizedDescription)
            item.fail(cause)
            completion?(.failed(cause))
        }
        return item
    }

    private func execute(
        _ request: TransferRequest,
        plan: TransferPlan,
        item: TransferItem,
        sourceSession: Session?,
        destinationSession: Session?,
        sourceManager: SFTPManager?,
        destinationManager: SFTPManager?,
        completion: (@MainActor (TransferResult) -> Void)?
    ) {
        switch plan.engine {
        case .localCopy:
            executeLocal(request, plan: plan, item: item, completion: completion)
        case .sftpGet, .recursiveSFTPGet:
            guard let sourceSession, let sourceManager else {
                finish(item, .failed(.connectionLost), completion)
                return
            }
            sourceManager.executePipelineDownload(request: request, plan: plan, session: sourceSession, item: item) { [weak self] result in
                self?.finish(item, result, completion)
            }
        case .sftpPut, .recursiveSFTPPut:
            guard let destinationSession, let destinationManager else {
                finish(item, .failed(.connectionLost), completion)
                return
            }
            destinationManager.executePipelineUpload(request: request, plan: plan, session: destinationSession, item: item) { [weak self] result in
                self?.finish(item, result, completion)
            }
        case .sftpRename:
            guard let sourceSession, let sourceManager else {
                finish(item, .failed(.connectionLost), completion)
                return
            }
            sourceManager.executePipelineMove(request: request, plan: plan, session: sourceSession, item: item) { [weak self] result in
                self?.finish(item, result, completion)
            }
        case .verifiedServerCopy:
            guard let sourceSession, let sourceManager else {
                finish(item, .failed(.connectionLost), completion)
                return
            }
            sourceManager.executePipelineServerCopy(request: request, plan: plan, session: sourceSession, item: item) { [weak self] result in
                self?.finish(item, result, completion)
            }
        case .localRelay:
            executeRelay(request, plan: plan, item: item, sourceSession: sourceSession,
                         destinationSession: destinationSession, sourceManager: sourceManager,
                         destinationManager: destinationManager, completion: completion)
        case .rsyncGetFallback, .rsyncPutFallback:
            finish(item, .failed(.unsupportedCapability), completion)
        }
    }

    private func executeLocal(_ request: TransferRequest, plan: TransferPlan, item: TransferItem,
                              completion: (@MainActor (TransferResult) -> Void)?) {
        item.transferState = .preparing
        let fm = FileManager.default
        let source = URL(fileURLWithPath: request.sourcePath)
        var final = URL(fileURLWithPath: plan.finalDestination)
        do {
            if fm.fileExists(atPath: final.path) {
                switch request.conflictPolicy {
                case .fail: throw TransferFailureCause.destinationExists
                case .cancel: throw TransferFailureCause.cancelled
                case .overwrite: try fm.removeItem(at: final)
                case .keepBoth:
                    let base = final.deletingPathExtension()
                    let ext = final.pathExtension
                    var index = 2
                    repeat {
                        let suffix = ext.isEmpty ? " copy \(index)" : " copy \(index).\(ext)"
                        final = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + suffix)
                        index += 1
                    } while fm.fileExists(atPath: final.path)
                case .merge:
                    guard request.itemType == .directory else { throw TransferFailureCause.destinationExists }
                    try mergeDirectory(source: source, destination: final, fileManager: fm)
                    item.status = .completed
                    item.transferState = .completed
                    item.percentDone = 100
                    finish(item, .success, completion)
                    return
                }
            }
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = final.deletingLastPathComponent().appendingPathComponent(".\(final.lastPathComponent).sshstudio-partial-\(UUID().uuidString)")
            try? fm.removeItem(at: partial)
            try fm.copyItem(at: source, to: partial)
            try fm.moveItem(at: partial, to: final)
            item.status = .completed
            item.transferState = .completed
            item.percentDone = 100
            finish(item, .success, completion)
        } catch let cause as TransferFailureCause {
            finish(item, .failed(cause), completion)
        } catch {
            finish(item, .failed(TransferFailureClassifier.classify(error.localizedDescription)), completion)
        }
    }

    private func mergeDirectory(source: URL, destination: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory { try mergeDirectory(source: child, destination: target, fileManager: fileManager) }
                else { try fileManager.removeItem(at: target); try fileManager.copyItem(at: child, to: target) }
            } else {
                try fileManager.copyItem(at: child, to: target)
            }
        }
    }

    private func executeRelay(
        _ request: TransferRequest,
        plan: TransferPlan,
        item: TransferItem,
        sourceSession: Session?,
        destinationSession: Session?,
        sourceManager: SFTPManager?,
        destinationManager: SFTPManager?,
        completion: (@MainActor (TransferResult) -> Void)?
    ) {
        guard let sourceSession, let destinationSession, let sourceManager, let destinationManager else {
            finish(item, .failed(.connectionLost), completion)
            return
        }
        let relayRoot = FileManager.default.temporaryDirectory.appendingPathComponent("sshstudio-relay-\(UUID().uuidString)", isDirectory: true)
        let relayURL = relayRoot.appendingPathComponent(TransferPlanner.basename(of: request.sourcePath, endpoint: request.sourceEndpoint))
        do { try FileManager.default.createDirectory(at: relayRoot, withIntermediateDirectories: true) }
        catch { finish(item, .failed(.processFailure(error.localizedDescription)), completion); return }

        let localRequest = TransferRequest(sourceEndpoint: request.sourceEndpoint, destinationEndpoint: .local,
                                           itemType: request.itemType, sourcePath: request.sourcePath,
                                           destinationDirectory: relayRoot.path, destinationName: relayURL.lastPathComponent,
                                           conflictPolicy: .overwrite, symlinkPolicy: request.symlinkPolicy)
        guard let localPlan = try? TransferPlanner.plan(for: localRequest) else {
            finish(item, .failed(.invalidPath), completion); return
        }
        sourceManager.executePipelineDownload(request: localRequest, plan: localPlan, session: sourceSession, item: item) { [weak self] result in
            guard let self else { return }
            guard result == .success else {
                try? FileManager.default.removeItem(at: relayRoot)
                self.finish(item, result, completion)
                return
            }
            let destinationRequest = TransferRequest(sourceEndpoint: .local, destinationEndpoint: request.destinationEndpoint,
                                                     itemType: request.itemType, operation: request.operation,
                                                     sourcePath: relayURL.path, destinationDirectory: request.destinationDirectory,
                                                     destinationName: TransferPlanner.basename(of: plan.finalDestination, endpoint: request.destinationEndpoint),
                                                     conflictPolicy: request.conflictPolicy, symlinkPolicy: request.symlinkPolicy)
            guard let destinationPlan = try? TransferPlanner.plan(for: destinationRequest) else {
                try? FileManager.default.removeItem(at: relayRoot)
                self.finish(item, .failed(.invalidPath), completion)
                return
            }
            destinationManager.executePipelineUpload(request: destinationRequest, plan: destinationPlan, session: destinationSession, item: item) { result in
                try? FileManager.default.removeItem(at: relayRoot)
                self.finish(item, result, completion)
            }
        }
    }

    private func finish(_ item: TransferItem, _ result: TransferResult,
                        _ completion: (@MainActor (TransferResult) -> Void)?) {
        switch result {
        case .success: item.transferState = .completed
        case .cancelled: item.fail(.cancelled)
        case .partial: item.transferState = .partial; item.status = .failed("Partial transfer")
        case .failed(let cause): item.fail(cause)
        }
        completion?(result)
    }
}

extension TransferStatus {
    var isSuccessful: Bool {
        if case .completed = self { return true }
        return false
    }
    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
    var isPartial: Bool { false }
}
