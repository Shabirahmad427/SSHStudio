import Foundation

@MainActor
enum SSHStudioDefaults {
    static let domain = "com.sshstudio.app"
    static let suiteOverrideEnvironmentKey = "SSHSTUDIO_DEFAULTS_SUITE"
    static let shared = makeSharedDefaults(environment: ProcessInfo.processInfo.environment)

    static func makeSharedDefaults(environment: [String: String]) -> UserDefaults {
        guard let suiteName = environment[suiteOverrideEnvironmentKey],
              !suiteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let defaults = UserDefaults(suiteName: suiteName)
        else {
            return .standard
        }
        return defaults
    }
}
