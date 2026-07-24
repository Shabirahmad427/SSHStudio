import Foundation
import Security

enum PromptKind: String {
    case password
    case passphrase
}

enum AskPassError: Error {
    case invalidArguments
    case unsupportedPrompt
    case invalidReference
    case keychain(OSStatus)
    case invalidData
}

let arguments = CommandLine.arguments.dropFirst()

func classifyPrompt(_ prompt: String) throws -> PromptKind {
    let lower = prompt.lowercased()
    if lower.contains("passphrase") { return .passphrase }
    if lower.contains("password") { return .password }
    throw AskPassError.unsupportedPrompt
}

func readCredential(reference: String) throws -> Data {
    guard UUID(uuidString: reference) != nil else { throw AskPassError.invalidReference }
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.sshstudio.app.credentials",
        kSecAttrAccount as String: reference,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess else { throw AskPassError.keychain(status) }
    guard let data = item as? Data else { throw AskPassError.invalidData }
    return data
}

do {
    guard arguments.count >= 2 else { throw AskPassError.invalidArguments }
    let reference = String(arguments[arguments.startIndex])
    let prompt = arguments.dropFirst().joined(separator: " ")
    _ = try classifyPrompt(prompt)
    let secret = try readCredential(reference: reference)
    FileHandle.standardOutput.write(secret)
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(EXIT_SUCCESS)
} catch {
    exit(EXIT_FAILURE)
}
