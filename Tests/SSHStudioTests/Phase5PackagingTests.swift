import Foundation
import Testing
@testable import SSHStudio

@Suite("SSH Studio Phase 5 Packaging")
struct Phase5PackagingTests {
    @Test func releaseMetadataIsValidAndMatchesSourcePlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let metadataURL = root.appendingPathComponent("Config/ReleaseMetadata.json")
        let plistURL = root.appendingPathComponent("Sources/SSHStudio/Resources/Info.plist")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: String]
        #expect(metadata?["bundleIdentifier"] == "com.sshstudio.app")
        #expect(metadata?["shortVersion"]?.split(separator: ".").count == 3)

        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: Any]
        #expect(plist?["CFBundleIdentifier"] as? String == metadata?["bundleIdentifier"])
        #expect(plist?["CFBundleVersion"] as? String == metadata?["buildNumber"])
        #expect(plist?["CFBundleShortVersionString"] as? String == metadata?["shortVersion"])
    }

    @Test func askPassPromptClassificationRejectsUnsupportedPrompts() throws {
        #expect(try AskPassSupport.classify(prompt: "Enter passphrase for key") == .passphrase)
        #expect(try AskPassSupport.classify(prompt: "user@example.com's password:") == .password)
        #expect(throws: AskPassValidationError.invalidPrompt) {
            try AskPassSupport.classify(prompt: "Verification code:")
        }
    }

    @Test func askPassHelperPathValidationRejectsExternalWritableHelpers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("SSH Studio.app")
        let helper = app.appendingPathComponent("Contents/Helpers/SSHStudioAskPass")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        try AskPassSupport.validateHelper(at: helper, appBundleURL: app)

        let external = root.appendingPathComponent("SSHStudioAskPass")
        FileManager.default.createFile(atPath: external.path, contents: Data())
        #expect(throws: AskPassValidationError.helperOutsideBundle) {
            try AskPassSupport.validateHelper(at: external, appBundleURL: app)
        }
        try? FileManager.default.removeItem(at: root)
    }
}
