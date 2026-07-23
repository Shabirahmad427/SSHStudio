import SwiftUI

enum SSHStudioColors {
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let paneBackground = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color(nsColor: .tertiaryLabelColor)
    static let selection = Color.accentColor
}

enum StudioTheme {
    static let accent = Color.accentColor
    static let accentBlue = Color.blue
    static let accentPurple = Color.purple
    static let background = SSHStudioColors.windowBackground
    static let panel = SSHStudioColors.paneBackground
    static let glassStroke = SSHStudioColors.separator.opacity(0.65)
}
