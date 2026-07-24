import Foundation
import SwiftUI

extension Notification.Name {
    static let showSSHStudioCommandPalette = Notification.Name("showSSHStudioCommandPalette")
    static let showSSHStudioQuickConnect = Notification.Name("showSSHStudioQuickConnect")
    static let showSSHStudioKnownHosts = Notification.Name("showSSHStudioKnownHosts")
    static let sshStudioHostTrustApproved = Notification.Name("sshStudioHostTrustApproved")
    static let showSSHStudioNewConnection = Notification.Name("showSSHStudioNewConnection")
    static let toggleSSHStudioSidebar = Notification.Name("toggleSSHStudioSidebar")
    static let toggleSSHStudioInspector = Notification.Name("toggleSSHStudioInspector")
    static let duplicateSSHStudioActiveTab = Notification.Name("duplicateSSHStudioActiveTab")
    static let closeSSHStudioActiveTab = Notification.Name("closeSSHStudioActiveTab")
    static let reconnectSSHStudioActiveSession = Notification.Name("reconnectSSHStudioActiveSession")
    static let disconnectSSHStudioActiveSession = Notification.Name("disconnectSSHStudioActiveSession")
    static let cancelSSHStudioReconnect = Notification.Name("cancelSSHStudioReconnect")
    static let findSSHStudioTerminal = Notification.Name("findSSHStudioTerminal")
    static let findNextSSHStudioTerminal = Notification.Name("findNextSSHStudioTerminal")
    static let findPreviousSSHStudioTerminal = Notification.Name("findPreviousSSHStudioTerminal")
    static let closeFindSSHStudioTerminal = Notification.Name("closeFindSSHStudioTerminal")
    static let selectSSHStudioNextTab = Notification.Name("selectSSHStudioNextTab")
    static let selectSSHStudioPreviousTab = Notification.Name("selectSSHStudioPreviousTab")
    static let increaseSSHStudioTerminalFont = Notification.Name("increaseSSHStudioTerminalFont")
    static let decreaseSSHStudioTerminalFont = Notification.Name("decreaseSSHStudioTerminalFont")
    static let resetSSHStudioTerminalFont = Notification.Name("resetSSHStudioTerminalFont")
}

struct HostKeyTrustSheetItem: Identifiable {
    let id = UUID()
    let state: SSHHostTrustState
}

enum SessionTab: String, CaseIterable {
    case terminal = "Terminal"
    case sftp = "SFTP"
    case screen = "Screen"
    case tunnels = "Tunnels"
    case sync = "Sync"
    case transfers = "Transfers"
    case keys = "Keys"

    static let workspaceOrder: [SessionTab] = [
        .terminal, .sftp, .screen, .tunnels, .sync, .transfers, .keys
    ]

    var icon: String {
        switch self {
        case .terminal: return "terminal"
        case .sftp: return "folder"
        case .screen: return "display"
        case .tunnels: return "point.3.connected.trianglepath.dotted"
        case .sync: return "arrow.left.arrow.right"
        case .transfers: return "arrow.up.arrow.down"
        case .keys: return "key"
        }
    }

    var color: Color {
        switch self {
        case .terminal: return .green
        case .sftp: return .blue
        case .screen: return .cyan
        case .tunnels: return .purple
        case .sync: return .orange
        case .transfers: return .mint
        case .keys: return .yellow
        }
    }
}

@MainActor
final class OpenSession: Identifiable, ObservableObject {
    let id = UUID()
    @Published var session: Session
    @Published var activeTab: SessionTab = .terminal
    let sftpManager = SFTPManager()
    let connectionService = SSHConnectionService()
    let terminalController: TerminalSessionController
    let sftpLocalHistory = NavigationHistory<URL>(initial: URL(fileURLWithPath: NSHomeDirectory()))

    init(session: Session) {
        self.session = session
        self.terminalController = TerminalSessionController(connectionService: connectionService)
    }
}
