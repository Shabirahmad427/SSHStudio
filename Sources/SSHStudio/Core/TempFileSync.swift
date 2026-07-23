import Foundation

/// Watches a locally-downloaded temp file and re-uploads it to the server
/// whenever the user saves changes in their editor.
@MainActor
final class TempFileSync {

    private struct WatchEntry {
        let tempURL: URL
        let remotePath: String
        let sessionName: String
        let upload: (URL, @escaping @MainActor () -> Void) -> Void
        var lastModified: Date?
        var isUploading: Bool = false
        var timer: Timer?
    }

    private var entries: [String: WatchEntry] = [:]   // keyed by remotePath

    func watch(
        tempURL: URL,
        remotePath: String,
        sessionName: String,
        upload: @escaping @MainActor (URL, @escaping @MainActor () -> Void) -> Void
    ) {
        // Stop any previous watcher for this remote path
        stopWatching(remotePath: remotePath)

        let initialDate = modDate(tempURL)
        var entry = WatchEntry(
            tempURL: tempURL,
            remotePath: remotePath,
            sessionName: sessionName,
            upload: upload,
            lastModified: initialDate
        )

        ConnectionLog.shared.log(
            "Watching \(tempURL.lastPathComponent) for changes (remote: \(remotePath))",
            level: .info,
            session: sessionName
        )

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(remotePath: remotePath)
            }
        }
        entry.timer = timer
        entries[remotePath] = entry
    }

    func stopWatching(remotePath: String) {
        entries[remotePath]?.timer?.invalidate()
        entries.removeValue(forKey: remotePath)
    }

    private func tick(remotePath: String) {
        guard var entry = entries[remotePath] else { return }
        guard !entry.isUploading else { return }

        let current = modDate(entry.tempURL)
        guard current != entry.lastModified else { return }

        entry.lastModified = current
        entry.isUploading = true
        entries[remotePath] = entry

        ConnectionLog.shared.log(
            "Change detected in \(entry.tempURL.lastPathComponent) — uploading to \(remotePath)",
            level: .info,
            session: entry.sessionName
        )

        entry.upload(entry.tempURL) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.entries[remotePath]?.isUploading = false
                ConnectionLog.shared.log(
                    "Saved \(entry.tempURL.lastPathComponent) to server",
                    level: .success,
                    session: entry.sessionName
                )
            }
        }
    }

    private func modDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
