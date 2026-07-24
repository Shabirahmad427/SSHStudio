import Foundation

struct SFTPPath: Codable, Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.rawValue = "~"
            return
        }
        guard !trimmed.contains("\u{0}") && !trimmed.contains("\n") && !trimmed.contains("\r") else {
            throw SFTPError.invalidRemotePath
        }
        self.rawValue = Self.collapseRepeatedSeparators(in: trimmed)
    }

    static let home = try! SFTPPath("~")

    var isHome: Bool { rawValue == "~" }

    func appending(component: String) throws -> SFTPPath {
        guard !component.isEmpty,
              !component.contains("\u{0}"),
              !component.contains("/"),
              !component.contains("\n"),
              !component.contains("\r") else {
            throw SFTPError.invalidRemotePath
        }
        if rawValue == "/" { return try SFTPPath("/\(component)") }
        return try SFTPPath("\(rawValue)/\(component)")
    }

    func parent() throws -> SFTPPath {
        if rawValue == "/" || rawValue == "~" { return self }
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let slash = trimmed.lastIndex(of: "/") else {
            return rawValue.hasPrefix("~/") ? .home : try SFTPPath("/")
        }
        let prefix = String(trimmed[..<slash])
        if rawValue.hasPrefix("/") {
            return try SFTPPath("/\(prefix)")
        }
        return try SFTPPath(prefix.isEmpty ? "~" : prefix)
    }

    var remoteShellEscaped: String {
        SSHSecurity.remoteShellPath(rawValue)
    }

    private static func collapseRepeatedSeparators(in value: String) -> String {
        if value == "~" { return value }
        var output = ""
        var previousWasSlash = false
        for character in value {
            if character == "/" {
                if !previousWasSlash { output.append(character) }
                previousWasSlash = true
            } else {
                output.append(character)
                previousWasSlash = false
            }
        }
        if output.count > 1, output.hasSuffix("/") {
            output.removeLast()
        }
        return output
    }
}

enum SFTPError: LocalizedError, Equatable {
    case invalidRemotePath
    case parseFailure(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemotePath:
            return "Remote path is invalid."
        case .parseFailure(let message), .operationFailed(let message):
            return DiagnosticRedactor.redact(message)
        }
    }
}
