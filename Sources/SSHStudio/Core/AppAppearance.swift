import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppAppearanceSettings: ObservableObject {
    static let shared = AppAppearanceSettings()

    @AppStorage("app_appearance", store: SSHStudioDefaults.shared) private var storedAppearance = AppAppearance.system.rawValue
    @Published var appearance: AppAppearance = .system {
        didSet {
            storedAppearance = appearance.rawValue
            apply()
        }
    }

    private init() {
        appearance = AppAppearance(rawValue: storedAppearance) ?? .system
        apply()
    }

    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }
}
