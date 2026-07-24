import Foundation

struct SFTPDirectoryEntry: Equatable, Sendable {
    let permissions: String
    let size: Int64?
    let name: String
    let isDirectory: Bool
}

enum SFTPDirectoryParser {
    static func parseListing(_ output: String) throws -> [SFTPDirectoryEntry] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .compactMap(parseLine)
    }

    static func parseLine(_ line: String) -> SFTPDirectoryEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return nil }
        let permissions = String(parts[0])
        let size = Int64(parts[4])
        let name = parts.dropFirst(8).joined(separator: " ")
        guard name != "." && name != ".." else { return nil }
        return SFTPDirectoryEntry(
            permissions: permissions,
            size: size,
            name: name,
            isDirectory: permissions.first == "d"
        )
    }
}
