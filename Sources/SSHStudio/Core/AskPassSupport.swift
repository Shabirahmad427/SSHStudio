import Foundation

enum AskPassPromptKind: String, Equatable {
    case password
    case passphrase
}

enum AskPassValidationError: LocalizedError, Equatable {
    case missingHelper
    case helperOutsideBundle
    case helperWritableByGroupOrOther
    case invalidPrompt

    var errorDescription: String? {
        switch self {
        case .missingHelper: return "AskPass helper is missing."
        case .helperOutsideBundle: return "AskPass helper is outside the application bundle."
        case .helperWritableByGroupOrOther: return "AskPass helper permissions are too permissive."
        case .invalidPrompt: return "AskPass prompt is not supported."
        }
    }
}

enum AskPassSupport {
    static let helperName = "SSHStudioAskPass"

    static func classify(prompt: String) throws -> AskPassPromptKind {
        let lower = prompt.lowercased()
        if lower.contains("passphrase") { return .passphrase }
        if lower.contains("password") { return .password }
        throw AskPassValidationError.invalidPrompt
    }

    static func validateHelper(at helperURL: URL, appBundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw AskPassValidationError.missingHelper
        }
        let bundlePath = appBundleURL.standardizedFileURL.path
        let helperPath = helperURL.standardizedFileURL.path
        guard helperPath.hasPrefix(bundlePath + "/") else {
            throw AskPassValidationError.helperOutsideBundle
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: helperPath)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        if permissions & 0o022 != 0 {
            throw AskPassValidationError.helperWritableByGroupOrOther
        }
    }

    static func helperURL(in appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName)
    }
}
