import AppKit
import SwiftUI

// MARK: - Color Theme

struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor

    static let themes: [TerminalTheme] = [
        .init(id: "ssh-studio", name: "SSH Studio",
              background: NSColor(red: 0.027, green: 0.067, blue: 0.102, alpha: 1),
              foreground: NSColor(red: 0.890, green: 0.965, blue: 0.970, alpha: 1),
              cursor:     NSColor(red: 0.290, green: 0.886, blue: 0.827, alpha: 1),
              selection:  NSColor(red: 0.055, green: 0.286, blue: 0.318, alpha: 1)),
        .init(id: "studio-contrast", name: "Studio Contrast",
              background: NSColor(red: 0.012, green: 0.027, blue: 0.043, alpha: 1),
              foreground: NSColor(red: 0.945, green: 0.985, blue: 0.990, alpha: 1),
              cursor:     NSColor(red: 0.357, green: 1.000, blue: 0.882, alpha: 1),
              selection:  NSColor(red: 0.000, green: 0.357, blue: 0.400, alpha: 1)),
        .init(id: "ocean", name: "Ocean",
              background: NSColor(red: 0.020, green: 0.094, blue: 0.153, alpha: 1),
              foreground: NSColor(red: 0.824, green: 0.933, blue: 1.000, alpha: 1),
              cursor:     NSColor(red: 0.271, green: 0.824, blue: 1.000, alpha: 1),
              selection:  NSColor(red: 0.055, green: 0.298, blue: 0.463, alpha: 1)),
        .init(id: "amber", name: "Amber",
              background: NSColor(red: 0.071, green: 0.047, blue: 0.016, alpha: 1),
              foreground: NSColor(red: 1.000, green: 0.812, blue: 0.376, alpha: 1),
              cursor:     NSColor(red: 1.000, green: 0.655, blue: 0.145, alpha: 1),
              selection:  NSColor(red: 0.318, green: 0.196, blue: 0.035, alpha: 1)),
        .init(id: "matrix", name: "Matrix",
              background: NSColor(red: 0.008, green: 0.047, blue: 0.024, alpha: 1),
              foreground: NSColor(red: 0.537, green: 0.957, blue: 0.639, alpha: 1),
              cursor:     NSColor(red: 0.310, green: 1.000, blue: 0.471, alpha: 1),
              selection:  NSColor(red: 0.039, green: 0.263, blue: 0.114, alpha: 1)),
        .init(id: "rose-pine", name: "Rose Pine",
              background: NSColor(red: 0.098, green: 0.075, blue: 0.149, alpha: 1),
              foreground: NSColor(red: 0.878, green: 0.831, blue: 0.910, alpha: 1),
              cursor:     NSColor(red: 0.922, green: 0.608, blue: 0.690, alpha: 1),
              selection:  NSColor(red: 0.251, green: 0.200, blue: 0.353, alpha: 1)),
        .init(id: "classic",    name: "Classic",
              background: NSColor(red: 0.0,  green: 0.0,  blue: 0.0,  alpha: 1),
              foreground: NSColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1),
              cursor:     NSColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1),
              selection:  NSColor(red: 0.2,  green: 0.45, blue: 0.75, alpha: 1)),
        .init(id: "solarized",  name: "Solarized Dark",
              background: NSColor(red: 0.0,  green: 0.169, blue: 0.212, alpha: 1),
              foreground: NSColor(red: 0.514, green: 0.580, blue: 0.588, alpha: 1),
              cursor:     NSColor(red: 0.847, green: 0.259, blue: 0.184, alpha: 1),
              selection:  NSColor(red: 0.027, green: 0.212, blue: 0.259, alpha: 1)),
        .init(id: "dracula",    name: "Dracula",
              background: NSColor(red: 0.157, green: 0.165, blue: 0.212, alpha: 1),
              foreground: NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1),
              cursor:     NSColor(red: 0.976, green: 0.663, blue: 0.416, alpha: 1),
              selection:  NSColor(red: 0.263, green: 0.278, blue: 0.353, alpha: 1)),
        .init(id: "nord",       name: "Nord",
              background: NSColor(red: 0.180, green: 0.204, blue: 0.251, alpha: 1),
              foreground: NSColor(red: 0.847, green: 0.871, blue: 0.914, alpha: 1),
              cursor:     NSColor(red: 0.533, green: 0.753, blue: 0.816, alpha: 1),
              selection:  NSColor(red: 0.231, green: 0.259, blue: 0.322, alpha: 1)),
        .init(id: "monokai",    name: "Monokai",
              background: NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 1),
              foreground: NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1),
              cursor:     NSColor(red: 0.976, green: 0.812, blue: 0.298, alpha: 1),
              selection:  NSColor(red: 0.298, green: 0.286, blue: 0.235, alpha: 1)),
        .init(id: "gruvbox",    name: "Gruvbox Dark",
              background: NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 1),
              foreground: NSColor(red: 0.922, green: 0.859, blue: 0.698, alpha: 1),
              cursor:     NSColor(red: 0.988, green: 0.733, blue: 0.145, alpha: 1),
              selection:  NSColor(red: 0.239, green: 0.220, blue: 0.212, alpha: 1)),
        .init(id: "light",      name: "Light",
              background: NSColor(red: 0.976, green: 0.976, blue: 0.976, alpha: 1),
              foreground: NSColor(red: 0.1,   green: 0.1,   blue: 0.1,   alpha: 1),
              cursor:     NSColor(red: 0.2,   green: 0.4,   blue: 0.8,   alpha: 1),
              selection:  NSColor(red: 0.8,   green: 0.88,  blue: 1.0,   alpha: 1)),
        .init(id: "paper",      name: "Paper",
              background: NSColor(red: 1.000, green: 0.992, blue: 0.961, alpha: 1),
              foreground: NSColor(red: 0.129, green: 0.153, blue: 0.180, alpha: 1),
              cursor:     NSColor(red: 0.000, green: 0.431, blue: 0.494, alpha: 1),
              selection:  NSColor(red: 0.753, green: 0.890, blue: 0.914, alpha: 1)),
        .init(id: "tango",      name: "Tango Dark",
              background: NSColor(red: 0.173, green: 0.173, blue: 0.173, alpha: 1),
              foreground: NSColor(red: 0.839, green: 0.839, blue: 0.839, alpha: 1),
              cursor:     NSColor(red: 0.204, green: 0.647, blue: 0.325, alpha: 1),
              selection:  NSColor(red: 0.255, green: 0.255, blue: 0.255, alpha: 1)),
    ]

    static var `default`: TerminalTheme { themes[0] }
}

enum TerminalFontWeight: String, CaseIterable {
    case regular = "Regular"
    case medium = "Medium"
    case semibold = "Semibold"

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }
}

// MARK: - Settings Model

@MainActor
class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    @Published var fontSize: CGFloat = 17 { didSet { defaults.set(Double(fontSize), forKey: "terminal_font_size") } }
    @Published var fontName: String = "" { didSet { defaults.set(fontName, forKey: "terminal_font_name") } }
    @Published var fontWeight: TerminalFontWeight = .medium { didSet { defaults.set(fontWeight.rawValue, forKey: "terminal_font_weight") } }
    @Published var themeID: String = "ssh-studio" { didSet { defaults.set(themeID, forKey: "terminal_theme") } }
    @Published var cursorColor: Color = .white
    @Published var textColor: Color = .white
    @Published var backgroundColor: Color = .black
    @Published var selectionColor: Color = Color(NSColor(red: 0.2, green: 0.45, blue: 0.75, alpha: 1))
    @Published var useCustomColors: Bool = false { didSet { defaults.set(useCustomColors, forKey: "terminal_use_custom_colors") } }

    private let defaults = SSHStudioDefaults.shared

    private init() {
        if defaults.object(forKey: "terminal_font_size") != nil {
            fontSize = CGFloat(defaults.double(forKey: "terminal_font_size"))
        }
        if !defaults.bool(forKey: "terminal_readability_bump_v1"), fontSize < 17 {
            fontSize = 17
            defaults.set(true, forKey: "terminal_readability_bump_v1")
        }
        fontName = defaults.string(forKey: "terminal_font_name") ?? ""
        fontWeight = TerminalFontWeight(rawValue: defaults.string(forKey: "terminal_font_weight") ?? "") ?? .medium
        themeID = defaults.string(forKey: "terminal_theme") ?? "ssh-studio"
        useCustomColors = defaults.bool(forKey: "terminal_use_custom_colors")
    }

    var currentTheme: TerminalTheme {
        TerminalTheme.themes.first { $0.id == themeID } ?? .default
    }

    var resolvedFont: NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: fontSize) { return f }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: fontWeight.nsWeight)
    }

    var resolvedBackground: NSColor {
        useCustomColors ? NSColor(backgroundColor) : currentTheme.background
    }
    var resolvedForeground: NSColor {
        useCustomColors ? NSColor(textColor) : currentTheme.foreground
    }
    var resolvedCursor: NSColor {
        useCustomColors ? NSColor(cursorColor) : currentTheme.cursor
    }
    var resolvedSelection: NSColor {
        useCustomColors ? NSColor(selectionColor) : currentTheme.selection
    }
}
