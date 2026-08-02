import Foundation
import os

enum SFTPPerformancePhase: String, Sendable {
    case sessionStartup
    case proxyJumpStartup
    case authentication
    case firstDirectoryListing
    case subsequentDirectoryListing
    case parsing
    case modelCreation
    case mainActorUpdate
    case uploadPreparation
    case downloadPreparation
    case firstByte
    case totalTransfer
    case refreshAfterTransfer
}

struct SFTPPerformanceEvent: Sendable {
    let phase: SFTPPerformancePhase
    let duration: TimeInterval
    let entryCount: Int
    let processLaunches: Int
    let requestID: UInt64?
    let cacheState: String?
}

actor SFTPPerformanceRecorder {
    static let shared = SFTPPerformanceRecorder()

    private let logger = Logger(subsystem: "com.sshstudio.app", category: "sftp.performance")
    private(set) var events: [SFTPPerformanceEvent] = []
    private(set) var processLaunches = 0

    func record(
        _ phase: SFTPPerformancePhase,
        start: ContinuousClock.Instant,
        entryCount: Int = 0,
        requestID: UInt64? = nil,
        cacheState: String? = nil
    ) {
        let duration = Double(start.duration(to: .now).components.attoseconds) / 1_000_000_000_000_000_000
            + Double(start.duration(to: .now).components.seconds)
        let event = SFTPPerformanceEvent(
            phase: phase,
            duration: duration,
            entryCount: entryCount,
            processLaunches: processLaunches,
            requestID: requestID,
            cacheState: cacheState
        )
        events.append(event)
        logger.debug("phase=\(phase.rawValue, privacy: .public) duration_ms=\(duration * 1000, privacy: .public) entries=\(entryCount, privacy: .public) processes=\(self.processLaunches, privacy: .public)")
    }

    func recordProcessLaunch() {
        processLaunches += 1
    }

    func snapshot() -> [SFTPPerformanceEvent] {
        events
    }

    func reset() {
        events.removeAll()
        processLaunches = 0
    }
}

struct SFTPListingOptions: Hashable, Sendable {
    let showHiddenFiles: Bool
}

struct SFTPListingCacheKey: Hashable, Sendable {
    let profileID: UUID
    let normalizedPath: String
    let options: SFTPListingOptions
}

struct SFTPListingCacheEntry: Sendable {
    let files: [RemoteFile]
    let createdAt: Date
}

struct SFTPDirectoryCache {
    var ttl: TimeInterval = 8
    var capacity = 32

    private var storage: [SFTPListingCacheKey: SFTPListingCacheEntry] = [:]
    private var accessOrder: [SFTPListingCacheKey] = []

    init(ttl: TimeInterval = 8, capacity: Int = 32) {
        self.ttl = ttl
        self.capacity = capacity
    }

    mutating func value(for key: SFTPListingCacheKey, now: Date = Date()) -> (files: [RemoteFile], isFresh: Bool)? {
        guard let entry = storage[key] else { return nil }
        touch(key)
        return (entry.files, now.timeIntervalSince(entry.createdAt) <= ttl)
    }

    mutating func set(_ files: [RemoteFile], for key: SFTPListingCacheKey, now: Date = Date()) {
        storage[key] = SFTPListingCacheEntry(files: files, createdAt: now)
        touch(key)
        evictIfNeeded()
    }

    mutating func invalidate(profileID: UUID, path: String? = nil) {
        storage = storage.filter { key, _ in
            guard key.profileID == profileID else { return true }
            guard let path else { return false }
            return key.normalizedPath != path
        }
        accessOrder.removeAll { key in
            guard key.profileID == profileID else { return false }
            guard let path else { return true }
            return key.normalizedPath == path
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        accessOrder.removeAll()
    }

    private mutating func touch(_ key: SFTPListingCacheKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private mutating func evictIfNeeded() {
        while storage.count > capacity, let oldest = accessOrder.first {
            storage.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
    }
}

struct SFTPPersistentCapabilityCircuitBreaker {
    private var unavailableProfiles: Set<UUID> = []

    func shouldAttemptPersistent(profileID: UUID) -> Bool {
        !unavailableProfiles.contains(profileID)
    }

    mutating func markCompatibilityUnavailable(profileID: UUID) {
        unavailableProfiles.insert(profileID)
    }

    mutating func reset(profileID: UUID) {
        unavailableProfiles.remove(profileID)
    }

    mutating func resetAll() {
        unavailableProfiles.removeAll()
    }
}
