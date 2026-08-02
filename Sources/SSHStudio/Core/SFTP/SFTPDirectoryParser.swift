import Foundation

struct SFTPDirectoryEntry: Equatable, Sendable {
    let permissions: String
    let size: Int64?
    let name: String
    let isDirectory: Bool
    let modified: String
    let modifiedDate: Date?
}

enum SFTPDirectoryParser {
    static func parseListing(_ output: String) throws -> [SFTPDirectoryEntry] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap(parseLine)
    }

    static func parseLine<S: StringProtocol>(_ line: S) -> SFTPDirectoryEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return nil }
        guard !trimmed.hasPrefix("sftp>"),
              !trimmed.hasPrefix("Connected to "),
              !trimmed.hasPrefix("Changing to:") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return nil }
        let permissions = String(parts[0])
        guard isFileMode(permissions),
              Int(parts[1]) != nil
        else { return nil }
        let size = Int64(parts[4])
        let modified = "\(parts[5]) \(parts[6]) \(parts[7])"
        let name = parts.dropFirst(8).joined(separator: " ")
        guard name != "." && name != ".." else { return nil }
        return SFTPDirectoryEntry(
            permissions: permissions,
            size: size,
            name: name,
            isDirectory: permissions.first == "d",
            modified: modified,
            modifiedDate: parseModifiedDate(modified)
        )
    }

    private static func isFileMode(_ value: String) -> Bool {
        value.range(
            of: "^[bcdlps-][rwxStTs-]{9}[+@.]?$",
            options: .regularExpression
        ) != nil
    }

    private static let dateFormatterLock = NSLock()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm yyyy"
        return formatter
    }()
    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()

    static func parseModifiedDate(_ value: String, now: Date = Date()) -> Date? {
        let includesTime = value.contains(":")
        let normalized = includesTime ? "\(value) \(Calendar.current.component(.year, from: now))" : value
        return dateFormatterLock.withLock {
            includesTime ? timeFormatter.date(from: normalized) : yearFormatter.date(from: normalized)
        }
    }
}
