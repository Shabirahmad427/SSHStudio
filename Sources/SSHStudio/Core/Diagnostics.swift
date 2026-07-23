import Foundation

enum DiagnosticSeverity: String, Codable, Equatable {
    case debug
    case info
    case warning
    case error
}

enum DiagnosticCategory: String, Codable, Equatable {
    case connection
    case authentication
    case hostKey
    case tunnel
    case transfer
    case profile
    case system
}

struct DiagnosticEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let severity: DiagnosticSeverity
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        severity: DiagnosticSeverity,
        message: String,
        sensitiveValues: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.message = DiagnosticRedactor.redact(message, sensitiveValues: sensitiveValues)
    }

    var exportRepresentation: [String: String] {
        [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "category": category.rawValue,
            "severity": severity.rawValue,
            "message": message
        ]
    }
}

enum DiagnosticRedactor {
    static let placeholder = "<redacted>"

    static func redact(_ value: String, sensitiveValues: [String] = []) -> String {
        var redacted = value
        let sorted = sensitiveValues
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        for sensitive in sorted {
            redacted = redacted.replacingOccurrences(of: sensitive, with: placeholder)
        }

        let keyValuePatterns = [
            #"(?i)(password|passphrase|token|api[_-]?key|secret)=([^ \t\r\n]+)"#,
            #"(?i)(password|passphrase|token|api[_-]?key|secret):([^ \t\r\n]+)"#
        ]
        for pattern in keyValuePatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: "$1=\(placeholder)",
                options: .regularExpression
            )
        }

        let pathPatterns = [
            #"/Users/[^ \t\r\n]+/\.ssh/[^ \t\r\n]+"#,
            #"~/.ssh/[^ \t\r\n]+"#
        ]
        for pattern in pathPatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: placeholder,
                options: .regularExpression
            )
        }
        return redacted
    }

    static func redactedArguments(_ arguments: [String], sensitiveValues: [String] = []) -> [String] {
        arguments.map { redact($0, sensitiveValues: sensitiveValues) }
    }
}
