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

struct SFTPConflictDecision: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case overwrite
        case skip
        case rename(String)
        case cancel
    }

    let action: Action
}
