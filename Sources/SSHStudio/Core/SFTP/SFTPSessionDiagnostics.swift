import Foundation

enum SFTPSessionError: LocalizedError {
    case connectionFailed(String)
    case compatibilityUnavailable(String)
    case authenticationFailed(String)
    case hostVerificationFailed(String)
    case securityPolicyFailed(String)
    case startupTimeout
    case commandTimeout
    case notConnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "SFTP connection failed: \(m)"
        case .compatibilityUnavailable(let m): return "Persistent SFTP compatibility unavailable: \(m)"
        case .authenticationFailed(let m): return "SFTP authentication failed: \(m)"
        case .hostVerificationFailed(let m): return "SFTP host verification failed: \(m)"
        case .securityPolicyFailed(let m): return "SFTP security policy failed: \(m)"
        case .startupTimeout: return "SFTP session startup timed out"
        case .commandTimeout: return "SFTP command timed out"
        case .notConnected: return "SFTP session not connected"
        }
    }

    var allowsCompatibilityFallback: Bool {
        if case .compatibilityUnavailable = self { return true }
        return false
    }
}

enum SFTPExitClassifier {
    static func classifyStartupFailure(output: String, exitStatus: Int32?) -> SFTPSessionError {
        let lowercased = output.lowercased()
        if lowercased.contains("remote host identification has changed")
            || lowercased.contains("host key verification failed")
            || lowercased.contains("offending key")
            || lowercased.contains("the authenticity of host") {
            return .hostVerificationFailed("host verification failed")
        }
        if lowercased.contains("permission denied")
            || lowercased.contains("password:")
            || lowercased.contains("passphrase")
            || lowercased.contains("verification code") {
            return .authenticationFailed("authentication failed")
        }
        if lowercased.contains("bad configuration option")
            || lowercased.contains("unsupported option")
            || lowercased.contains("invalid port")
            || lowercased.contains("illegal option") {
            return .securityPolicyFailed("invalid SSH/SFTP invocation")
        }
        if lowercased.contains("connection closed")
            || lowercased.contains("connection lost")
            || lowercased.contains("received message too long")
            || exitStatus != nil {
            return .compatibilityUnavailable("persistent session closed before readiness")
        }
        return .connectionFailed("sftp exited before readiness")
    }
}

struct SFTPPromptDetector {
    private(set) var buffer = ""

    mutating func append(_ text: String) {
        buffer += text
        if buffer.count > 128_000 {
            buffer = String(buffer.suffix(128_000))
        }
    }

    mutating func consumePrompt() -> String? {
        guard let range = promptRange(in: buffer) else { return nil }
        let output = String(buffer[..<range.lowerBound])
        buffer = String(buffer[range.upperBound...])
        return output
    }

    private func promptRange(in value: String) -> Range<String.Index>? {
        var searchStart = value.startIndex
        while let range = value.range(of: "sftp>", range: searchStart..<value.endIndex) {
            let atLineBoundary = range.lowerBound == value.startIndex
                || value[value.index(before: range.lowerBound)].isNewline
                || value[value.index(before: range.lowerBound)] == "\r"
            let after = range.upperBound
            let hasPromptSuffix = after == value.endIndex
                || value[after] == " "
                || value[after].isNewline
                || value[after] == "\r"
            if atLineBoundary, hasPromptSuffix {
                var end = after
                while end < value.endIndex, value[end] == " " {
                    end = value.index(after: end)
                }
                return range.lowerBound..<end
            }
            searchStart = range.upperBound
        }
        return nil
    }
}
