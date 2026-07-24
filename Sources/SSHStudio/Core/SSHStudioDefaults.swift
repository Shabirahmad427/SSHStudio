import Foundation

@MainActor
enum SSHStudioDefaults {
    static let domain = "com.sshstudio.app"
    static let suiteOverrideEnvironmentKey = "SSHSTUDIO_DEFAULTS_SUITE"
    static let plistOverrideEnvironmentKey = "SSHSTUDIO_DEFAULTS_PLIST"
    static let shared = makeSharedDefaults(environment: ProcessInfo.processInfo.environment)

    static func makeSharedDefaults(
        environment: [String: String],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        bundledFixtureURL: URL? = Bundle.main.url(forResource: "fixture-defaults", withExtension: "plist")
    ) -> UserDefaults {
        guard let suiteName = previewSuiteName(environment: environment, bundleIdentifier: bundleIdentifier),
              let defaults = UserDefaults(suiteName: suiteName)
        else {
            return .standard
        }
        loadVolatilePreviewDomainIfNeeded(
            defaults: defaults,
            environment: environment,
            bundledFixtureURL: bundledFixtureURL
        )
        return defaults
    }

    private static func previewSuiteName(environment: [String: String], bundleIdentifier: String?) -> String? {
        if let suiteName = environment[suiteOverrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suiteName.isEmpty {
            return suiteName
        }
        guard let bundleIdentifier,
              bundleIdentifier.hasPrefix("com.sshstudio.phase")
        else {
            return nil
        }
        return "\(bundleIdentifier).defaults"
    }

    private static func loadVolatilePreviewDomainIfNeeded(
        defaults: UserDefaults,
        environment: [String: String],
        bundledFixtureURL: URL?
    ) {
        let environmentURL = environment[plistOverrideEnvironmentKey]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        guard let url = environmentURL ?? bundledFixtureURL,
              let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return
        }
        defaults.register(defaults: dictionary)
    }
}
