import Foundation

enum SFTPOperation: Equatable, Sendable {
    case listDirectory(SFTPPath)
    case upload(local: URL, remote: SFTPPath)
    case download(remote: SFTPPath, local: URL)
    case createDirectory(SFTPPath)
    case remove(SFTPPath)
}

enum SFTPTransferState: Equatable, Sendable {
    case queued
    case preparing
    case transferring(bytesTransferred: Int64, totalBytes: Int64?)
    case completed
    case failed(String)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .preparing, .transferring:
            return false
        }
    }
}

enum SFTPDownloadFailure: String, Equatable, Sendable {
    case remoteDirectoryNotFound
    case permissionDenied
    case listingFormatUnsupported
    case connectionClosed
    case authenticationFailed
    case localDestinationUnavailable
    case recursiveTransferUnsupported
    case transferCancelled
    case unknown

    var message: String {
        switch self {
        case .remoteDirectoryNotFound: return "Remote directory not found"
        case .permissionDenied: return "Permission denied"
        case .listingFormatUnsupported: return "Remote listing format unsupported"
        case .connectionClosed: return "Connection closed"
        case .authenticationFailed: return "Authentication failed"
        case .localDestinationUnavailable: return "Local destination unavailable"
        case .recursiveTransferUnsupported: return "Recursive SFTP transfer unsupported"
        case .transferCancelled: return "Transfer cancelled"
        case .unknown: return "Download failed"
        }
    }
}

enum SFTPDownloadDiagnostics {
    static func classify(_ output: String, exitStatus: Int32? = nil) -> SFTPDownloadFailure {
        let lower = output.lowercased()
        if lower.contains("permission denied") { return .permissionDenied }
        if lower.contains("no such file") || lower.contains("not found") { return .remoteDirectoryNotFound }
        if lower.contains("connection closed") || lower.contains("connection lost") { return .connectionClosed }
        if lower.contains("authentication") || lower.contains("permission denied (publickey") { return .authenticationFailed }
        if lower.contains("invalid flag") || lower.contains("invalid command") || lower.contains("usage: get") {
            return .recursiveTransferUnsupported
        }
        if lower.contains("parse") || lower.contains("unsupported") { return .listingFormatUnsupported }
        if exitStatus == 0 { return .unknown }
        return .unknown
    }
}

enum SFTPLocalConflictAction: Equatable, Sendable {
    case replace
    case merge
    case keepBoth(URL)
    case cancel
}

enum SFTPRecursiveDownloadBuilder {
    static func command(remotePath: String, localPartialPath: String) throws -> String {
        _ = try SFTPPath(remotePath)
        return "get -a -R \(sftpPath(remotePath)) \(localPath(localPartialPath))"
    }

    static func sftpPath(_ value: String) -> String {
        if value == "~" { return "." }
        if value.hasPrefix("~/") {
            return localPath(String(value.dropFirst(2)))
        }
        return localPath(value)
    }

    static func localPath(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

struct SFTPConflictDecision: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case overwrite
        case skip
        case rename(String)
        case cancel
    }

    let action: Action
}
