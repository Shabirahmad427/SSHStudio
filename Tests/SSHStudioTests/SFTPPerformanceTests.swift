import Foundation
import Testing
@testable import SSHStudio

@Suite("SFTP performance candidate")
struct SFTPPerformanceTests {
    @Test func parserHandlesLargeListingsDeterministically() throws {
        for count in [100, 1_000, 10_000] {
            let listing = Self.fixtureListing(count: count)
            let start = ContinuousClock.now
            let entries = try SFTPDirectoryParser.parseListing(listing)
            let elapsed = start.duration(to: .now)

            #expect(entries.count == count)
            #expect(entries[0].name == "folder-00000")
            #expect(entries[count - 1].name == "file-\(String(format: "%05d", count - 1)).dat")
            #expect(elapsed < .seconds(3))
        }
    }

    @Test func directoryCacheHitsExpiresInvalidatesAndEvicts() {
        let profileID = UUID()
        var cache = SFTPDirectoryCache(ttl: 1, capacity: 2)
        let options = SFTPListingOptions(showHiddenFiles: false)
        let keyA = SFTPListingCacheKey(profileID: profileID, normalizedPath: "/a", options: options)
        let keyB = SFTPListingCacheKey(profileID: profileID, normalizedPath: "/b", options: options)
        let keyC = SFTPListingCacheKey(profileID: profileID, normalizedPath: "/c", options: options)
        let file = RemoteFile(name: "a.txt", isDirectory: false, size: "1", permissions: "-rw-r--r--", modified: "Aug 2 10:00", modifiedDate: nil)
        let now = Date()

        cache.set([file], for: keyA, now: now)
        #expect(cache.value(for: keyA, now: now.addingTimeInterval(0.5))?.isFresh == true)
        #expect(cache.value(for: keyA, now: now.addingTimeInterval(2))?.isFresh == false)

        cache.set([file], for: keyB, now: now)
        cache.set([file], for: keyC, now: now)
        #expect(cache.value(for: keyA, now: now) == nil)
        #expect(cache.value(for: keyB, now: now) != nil)

        cache.invalidate(profileID: profileID, path: "/b")
        #expect(cache.value(for: keyB, now: now) == nil)
        #expect(cache.value(for: keyC, now: now) != nil)

        cache.invalidate(profileID: profileID)
        #expect(cache.value(for: keyC, now: now) == nil)
    }

    @Test func remoteFileIdentityIsStableAcrossRefreshes() {
        let first = RemoteFile(name: "result.xtc", isDirectory: false, size: "42", permissions: "-rw-r--r--", modified: "Aug 2 10:00", modifiedDate: nil)
        let second = RemoteFile(name: "result.xtc", isDirectory: false, size: "42", permissions: "-rw-r--r--", modified: "Aug 2 10:00", modifiedDate: nil)
        let changed = RemoteFile(name: "result.xtc", isDirectory: false, size: "43", permissions: "-rw-r--r--", modified: "Aug 2 10:00", modifiedDate: nil)

        #expect(first.id == second.id)
        #expect(first.id != changed.id)
    }

    @Test @MainActor func transferProgressUpdatesAreThrottled() {
        let item = TransferItem(name: "large.bin", direction: .download)
        let now = Date()

        item.applyProgress(bytesTransferred: 100, percentDone: 10, speedBytesPerSec: 1_000, eta: "0:09", now: now)
        item.applyProgress(bytesTransferred: 200, percentDone: 20, speedBytesPerSec: 1_000, eta: "0:08", now: now.addingTimeInterval(0.05))
        #expect(item.bytesTransferred == 100)
        #expect(item.percentDone == 10)

        item.applyProgress(bytesTransferred: 300, percentDone: 30, speedBytesPerSec: 1_000, eta: "0:07", now: now.addingTimeInterval(0.25))
        #expect(item.bytesTransferred == 300)
        #expect(item.percentDone == 30)

        item.applyProgress(bytesTransferred: 1_000, percentDone: 100, speedBytesPerSec: 1_000, eta: "0:00", now: now.addingTimeInterval(0.26))
        #expect(item.percentDone == 100)
    }

    @Test func controlPathIsUniqueAndDirectoryIsRestrictive() throws {
        let id = UUID()
        let agentSession = Session(id: id, name: "A", host: "example.com", username: "me", authentication: .sshAgent)
        let keySession = Session(id: id, name: "A", host: "example.com", username: "me", authentication: .privateKey(path: "/tmp/key-a", useAgent: true, addKeysToAgent: false, useKeychain: false), privateKeyPath: "/tmp/key-a")

        #expect(SSHSecurity.controlPath(for: agentSession) != SSHSecurity.controlPath(for: keySession))

        let directory = SSHSecurity.controlSocketDirectory()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
        #expect(permissions & 0o077 == 0)
        #expect(!directory.path.hasPrefix("/tmp/ssh-studio.sock"))
    }

    @Test func fakeBenchmarkShowsPersistentBrowsingAvoidsPerNavigationLaunches() async throws {
        let listing = Self.fixtureListing(count: 1_000)
        let legacy = FakeSFTPProcessAdapter(listing: listing, persistent: false, latency: .milliseconds(2))
        let optimized = FakeSFTPProcessAdapter(listing: listing, persistent: true, latency: .milliseconds(2))

        for index in 0..<10 {
            _ = try await legacy.list(path: "/dir-\(index)")
            _ = try await optimized.list(path: "/dir-\(index)")
        }

        #expect(await legacy.processLaunches == 10)
        #expect(await optimized.processLaunches == 1)
    }

    private static func fixtureListing(count: Int) -> String {
        (0..<count).map { index in
            let name = index.isMultiple(of: 10)
                ? "folder-\(String(format: "%05d", index))"
                : "file-\(String(format: "%05d", index)).dat"
            let mode = index.isMultiple(of: 10) ? "drwxr-xr-x" : "-rw-r--r--"
            return "\(mode)  1 user group \(1024 + index) Aug  2 10:00 \(name)"
        }.joined(separator: "\n")
    }
}

private actor FakeSFTPProcessAdapter {
    private let listing: String
    private let persistent: Bool
    private let latency: Duration
    private var connected = false
    private(set) var processLaunches = 0

    init(listing: String, persistent: Bool, latency: Duration) {
        self.listing = listing
        self.persistent = persistent
        self.latency = latency
    }

    func list(path: String) async throws -> [SFTPDirectoryEntry] {
        _ = path
        if !persistent || !connected {
            processLaunches += 1
            connected = true
        }
        try await Task.sleep(for: latency)
        return try SFTPDirectoryParser.parseListing(listing)
    }
}
