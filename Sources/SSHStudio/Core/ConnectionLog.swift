import Foundation

enum LogLevel: String {
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERROR"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let session: String
    let message: String

    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }
}

@MainActor
class ConnectionLog: ObservableObject {
    static let shared = ConnectionLog()
    @Published var entries: [LogEntry] = []

    func log(_ message: String, level: LogLevel = .info, session: String = "System") {
        let entry = LogEntry(timestamp: Date(), level: level, session: session, message: message)
        Task { @MainActor in
            self.entries.insert(entry, at: 0)
        }
    }

    func clear() { entries.removeAll() }
}
