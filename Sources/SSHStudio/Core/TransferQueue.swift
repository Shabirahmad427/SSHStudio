import Foundation
import Combine

enum TransferDirection { case upload, download, serverToServer }
enum TransferStatus {
    case queued
    case preparing
    case inProgress
    case completed
    case failed(String)
    case cancelled
    case skipped
}

@MainActor
class TransferItem: Identifiable, ObservableObject, @unchecked Sendable {
    private static let maxDetailLines = 80
    private static let maxDetailLineLength = 400
    private static let maxStatusMessageLength = 500

    let id = UUID()
    let name: String
    let direction: TransferDirection
    @Published var status: TransferStatus = .queued
    @Published var bytesTransferred: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var speedBytesPerSec: Double = 0     // bytes/s
    @Published var eta: String = ""                 // e.g. "0:02:15"
    @Published var percentDone: Double = 0          // 0–100
    @Published var profileLabel: String = ""
    @Published var detailLines: [String] = []
    let createdAt = Date()
    var startedAt: Date?
    private var recordedDetailLines: Set<String> = []
    private var runningProcess: Process?
    private var isCancellationRequested = false
    private var isSkipRequested = false
    private var lastProgressUpdate = Date.distantPast

    var progress: Double { percentDone / 100.0 }
    var isTerminal: Bool {
        switch status {
        case .completed, .failed, .cancelled, .skipped: return true
        default: return false
        }
    }

    var speedLabel: String {
        guard speedBytesPerSec > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(speedBytesPerSec), countStyle: .file) + "/s"
    }

    var transferredLabel: String {
        let done = ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
        if totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(done) / \(total)"
        }
        return done
    }

    var statusLabel: String {
        switch status {
        case .queued:        return "Queued"
        case .preparing:     return "Preparing"
        case .inProgress:    return "Transferring…"
        case .completed:
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let s = Int(elapsed) % 60
            let m = Int(elapsed) / 60
            let timeStr = m > 0 ? "\(m)m \(s)s" : "\(s)s"
            return "Done in \(timeStr)"
        case .failed(let e): return "Failed: \(Self.truncate(e, limit: Self.maxStatusMessageLength))"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        }
    }

    var failureLabel: String? {
        guard case .failed(let error) = status else { return nil }
        return Self.truncate(error, limit: Self.maxStatusMessageLength)
    }

    init(name: String, direction: TransferDirection) {
        self.name = name
        self.direction = direction
    }

    func addDetailLine(_ line: String) {
        let trimmed = Self.truncate(
            line.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: Self.maxDetailLineLength
        )
        guard !trimmed.isEmpty, !recordedDetailLines.contains(trimmed) else { return }
        recordedDetailLines.insert(trimmed)
        detailLines.insert(trimmed, at: 0)
        detailLines = Array(detailLines.prefix(Self.maxDetailLines))
        recordedDetailLines = Set(detailLines)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return "\(value.prefix(limit))... [truncated]"
    }

    func attach(_ process: Process) {
        runningProcess = process
        isCancellationRequested = false
        isSkipRequested = false
    }

    func cancel() {
        guard !isTerminal else { return }
        isCancellationRequested = true
        runningProcess?.terminate()
    }

    func skip() {
        guard !isTerminal else { return }
        isSkipRequested = true
        runningProcess?.terminate()
    }

    func finishCancellationIfNeeded() -> TransferStatus? {
        if isSkipRequested {
            return .skipped
        }
        if isCancellationRequested {
            return .cancelled
        }
        return nil
    }

    func clearProcess() {
        runningProcess = nil
    }

    func applyProgress(
        bytesTransferred: Int64,
        percentDone: Double,
        speedBytesPerSec: Double,
        eta: String,
        minimumInterval: TimeInterval = 0.2,
        now: Date = Date()
    ) {
        guard now.timeIntervalSince(lastProgressUpdate) >= minimumInterval || percentDone >= 100 else { return }
        lastProgressUpdate = now
        self.bytesTransferred = bytesTransferred
        self.percentDone = percentDone
        self.speedBytesPerSec = speedBytesPerSec
        self.eta = eta
        if percentDone > 0 {
            totalBytes = Int64(Double(bytesTransferred) / (percentDone / 100.0))
        }
    }
}

@MainActor
class TransferQueue: ObservableObject {
    static let shared = TransferQueue()
    @Published var items: [TransferItem] = []

    var activeCount: Int { items.filter { if case .inProgress = $0.status { return true }; return false }.count }
    var pendingCount: Int { items.filter { if case .queued = $0.status { return true }; return false }.count }

    func add(_ item: TransferItem) { items.insert(item, at: 0) }

    func clear() {
        items.removeAll {
            if case .completed = $0.status { return true }
            if case .failed = $0.status { return true }
            if case .cancelled = $0.status { return true }
            if case .skipped = $0.status { return true }
            return false
        }
    }

    func cancel(_ item: TransferItem) {
        item.cancel()
    }

    func skip(_ item: TransferItem) {
        item.skip()
    }

    func enqueue(name: String, direction: TransferDirection,
                 work: @escaping @Sendable (TransferItem) -> Void) {
        let item = TransferItem(name: name, direction: direction)
        add(item)
        let captured = item
        Task.detached {
            await MainActor.run {
                captured.status = .inProgress
                captured.startedAt = Date()
            }
            work(captured)
        }
    }
}
