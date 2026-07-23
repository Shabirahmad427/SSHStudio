import Foundation

@MainActor
enum SSHStudioDefaults {
    static let domain = "com.sshstudio.app"
    static let suiteOverrideEnvironmentKey = "SSHSTUDIO_DEFAULTS_SUITE"
    static let plistOverrideEnvironmentKey = "SSHSTUDIO_DEFAULTS_PLIST"
    static let shared = makeSharedDefaults(environment: ProcessInfo.processInfo.environment)

    static func makeSharedDefaults(environment: [String: String]) -> UserDefaults {
        guard let suiteName = environment[suiteOverrideEnvironmentKey],
              !suiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let defaults = UserDefaults(suiteName: suiteName)
        else {
            return .standard
        }
        loadVolatilePreviewDomainIfNeeded(defaults: defaults, suiteName: suiteName, environment: environment)
        return defaults
    }

    private static func loadVolatilePreviewDomainIfNeeded(
        defaults: UserDefaults,
        suiteName: String,
        environment: [String: String]
    ) {
        guard let plistPath = environment[plistOverrideEnvironmentKey],
              !plistPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return
        }
        defaults.register(defaults: dictionary)
    }
}
