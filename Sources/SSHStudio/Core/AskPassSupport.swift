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
    case invalidCredentialReference

    var errorDescription: String? {
        switch self {
        case .missingHelper: return "AskPass helper is missing."
        case .helperOutsideBundle: return "AskPass helper is outside the application bundle."
        case .helperWritableByGroupOrOther: return "AskPass helper permissions are too permissive."
        case .invalidPrompt: return "AskPass prompt is not supported."
        case .invalidCredentialReference: return "AskPass credential reference is invalid."
        }
    }
}

enum AskPassSupport {
    static let helperName = "SSHStudioAskPass"
    static let credentialReferenceEnvironmentKey = "SSHSTUDIO_ASKPASS_REFERENCE"

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

    static func environment(
        credentialReferenceID: String,
        appBundleURL: URL = Bundle.main.bundleURL
    ) throws -> [String: String] {
        guard UUID(uuidString: credentialReferenceID) != nil else {
            throw AskPassValidationError.invalidCredentialReference
        }
        let helper = helperURL(in: appBundleURL)
        try validateHelper(at: helper, appBundleURL: appBundleURL)
        return [
            "SSH_ASKPASS": helper.path,
            "SSH_ASKPASS_REQUIRE": "force",
            credentialReferenceEnvironmentKey: credentialReferenceID
        ]
    }
}
