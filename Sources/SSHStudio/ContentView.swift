import AppKit
import SwiftUI

extension Notification.Name {
    static let showSSHStudioCommandPalette = Notification.Name("showSSHStudioCommandPalette")
    static let showSSHStudioQuickConnect = Notification.Name("showSSHStudioQuickConnect")
    static let showSSHStudioKnownHosts = Notification.Name("showSSHStudioKnownHosts")
    static let sshStudioHostTrustApproved = Notification.Name("sshStudioHostTrustApproved")
}

private struct HostKeyTrustSheetItem: Identifiable {
    let id = UUID()
    let state: SSHHostTrustState
}

enum StudioTheme {
    static let accent = Color(red: 0.20, green: 0.78, blue: 0.73)
    static let accentBlue = Color(red: 0.25, green: 0.58, blue: 0.98)
    static let accentPurple = Color(red: 0.62, green: 0.42, blue: 0.96)
    static let background = Color(red: 0.025, green: 0.055, blue: 0.082)
    static let panel = Color(red: 0.043, green: 0.086, blue: 0.118)
    static let glassStroke = Color.white.opacity(0.20)
}

struct StudioBackdrop: View {
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            LinearGradient(
                colors: [
                    StudioTheme.accentBlue.opacity(0.07),
                    .clear,
                    StudioTheme.accent.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [StudioTheme.accent.opacity(0.15), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 760
            )
            RadialGradient(
                colors: [StudioTheme.accentBlue.opacity(0.13), .clear],
                center: .bottomTrailing,
                startRadius: 30,
                endRadius: 720
            )
            RadialGradient(
                colors: [StudioTheme.accentPurple.opacity(0.07), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 620
            )
        }
        .ignoresSafeArea()
    }
}

struct StudioGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.12 : 0.24), lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.12), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct TahoeMagnifyGlass: ViewModifier {
    let enabled: Bool
    let isActive: Bool
    let tint: Color
    var cornerRadius: CGFloat = 9
    var scale: CGFloat = 1.14
    var lift: CGFloat = 1
    var response: Double = 0.46
    var dampingFraction: Double = 0.94

    @State private var isHovered = false

    func body(content: Content) -> some View {
        let highlighted = enabled && (isActive || isHovered)
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear))
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: highlighted
                                ? [
                                    Color.white.opacity(isHovered ? 0.26 : 0.16),
                                    tint.opacity(isHovered ? 0.12 : 0.07),
                                    Color.white.opacity(isHovered ? 0.08 : 0.04)
                                ]
                                : [.clear, .clear, .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        highlighted ? Color.white.opacity(isHovered ? 0.46 : 0.30) : Color.white.opacity(0),
                        lineWidth: 0.7
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                    .strokeBorder(
                        highlighted ? tint.opacity(isActive ? 0.36 : 0.22) : Color.clear,
                        lineWidth: 0.6
                    )
            }
            .shadow(color: highlighted ? Color.white.opacity(isHovered ? 0.16 : 0.08) : .clear, radius: isHovered ? 4 : 2, y: 0)
            .shadow(color: highlighted ? tint.opacity(0.18) : .clear, radius: isHovered ? 12 : 5, y: isHovered ? 5 : 1)
            .scaleEffect(enabled && isHovered ? scale : 1, anchor: .bottom)
            .offset(y: enabled && isHovered ? -lift : 0)
            .zIndex(enabled && isHovered ? 10 : 0)
            .onHover { isHovered = enabled && $0 }
            .animation(.interactiveSpring(response: response, dampingFraction: dampingFraction, blendDuration: 0.28), value: isHovered)
            .animation(.easeOut(duration: 0.24), value: isActive)
    }
}

extension View {
    func tahoeMagnifyGlass(
        enabled: Bool = true,
        isActive: Bool = false,
        tint: Color = .accentColor,
        cornerRadius: CGFloat = 9,
        scale: CGFloat = 1.14,
        lift: CGFloat = 1,
        response: Double = 0.46,
        dampingFraction: Double = 0.94
    ) -> some View {
        modifier(TahoeMagnifyGlass(
            enabled: enabled,
            isActive: isActive,
            tint: tint,
            cornerRadius: cornerRadius,
            scale: scale,
            lift: lift,
            response: response,
            dampingFraction: dampingFraction
        ))
    }
}

// MARK: - Session Tab Enum

enum SessionTab: String, CaseIterable {
    case terminal    = "Terminal"
    case sftp        = "SFTP"
    case screen      = "Screen"
    case tunnels     = "Tunnels"
    case sync        = "Sync"
    case transfers   = "Transfers"
    case keys        = "Keys"

    static let workspaceOrder: [SessionTab] = [
        .terminal, .sftp, .screen, .tunnels, .sync, .transfers, .keys
    ]

    var icon: String {
        switch self {
        case .terminal:  return "terminal.fill"
        case .screen:    return "display"
        case .sftp:      return "folder.badge.gearshape"
        case .tunnels:   return "arrow.triangle.2.circlepath"
        case .sync:      return "arrow.left.arrow.right.circle.fill"
        case .transfers: return "arrow.up.arrow.down.circle.fill"
        case .keys:      return "key.fill"
        }
    }

    var color: Color {
        switch self {
        case .terminal:  return .mint
        case .screen:    return .cyan
        case .sftp:      return .blue
        case .tunnels:   return .purple
        case .sync:      return .orange
        case .transfers: return .green
        case .keys:      return .yellow
        }
    }
}

// MARK: - Open Session Model

@MainActor
class OpenSession: Identifiable, ObservableObject {
    let id = UUID()
    @Published var session: Session
    @Published var activeTab: SessionTab = .terminal
    let sftpManager = SFTPManager()
    let connectionService = SSHConnectionService()
    let sftpLocalHistory = NavigationHistory<URL>(initial: URL(fileURLWithPath: NSHomeDirectory()))
    init(session: Session) { self.session = session }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var sshManager = SSHManager()
    @StateObject private var hostKeyModel = HostKeyVerificationModel.shared
    @State private var openSessions: [OpenSession] = []
    @State private var selectedOpenID: UUID?
    @State private var showQuickConnect = false
    @State private var showCommandPalette = false
    @State private var showTerminalSettings = false
    @State private var showKnownHosts = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var selectedOpen: OpenSession? {
        openSessions.first { $0.id == selectedOpenID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store,
                openSessionIDs: openSessions.map { $0.session.id },
                onSelect: openOrSwitch,
                onQuickConnect: { showQuickConnect = true },
                onCommandPalette: { showCommandPalette = true }
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        } detail: {
            ZStack {
                StudioBackdrop()
                VStack(spacing: 0) {
                    if !openSessions.isEmpty {
                        SessionTabBar(
                            openSessions: openSessions,
                            selectedID: $selectedOpenID,
                            onClose: closeSession
                        )
                    }
                    if !openSessions.isEmpty {
                        ZStack {
                            ForEach(openSessions) { open in
                                let isSelected = selectedOpenID == open.id
                                SessionDetailWrapper(open: open, store: store, sshManager: sshManager)
                                    .opacity(isSelected ? 1 : 0)
                                    .allowsHitTesting(isSelected)
                                    .zIndex(isSelected ? 1 : 0)
                            }
                        }
                    } else {
                        WelcomeView(onQuickConnect: { showQuickConnect = true })
                    }
                }
            }
        }
        .background(StudioTheme.background)
        .frame(minWidth: 1120, minHeight: 700)
        .onAppear { columnVisibility = .all }
        .sheet(isPresented: $showQuickConnect) {
            QuickConnectView { session in
                store.add(session)
                openOrSwitch(session)
            }
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(
                sessions: store.sessions,
                hasOpenSession: selectedOpen != nil,
                onQuickConnect: { showQuickConnect = true },
                onOpenSession: openOrSwitch,
                onSelectTool: { selectedOpen?.activeTab = $0 },
                onTerminalSettings: { showTerminalSettings = true }
            )
        }
        .sheet(isPresented: $showTerminalSettings) {
            TerminalSettingsView()
        }
        .sheet(isPresented: $showKnownHosts) {
            KnownHostsView()
        }
        .sheet(item: hostKeyTrustSheetBinding) { item in
            HostKeyTrustSheet(
                state: item.state,
                onTrust: { candidate in
                    Task {
                        do {
                            try await hostKeyModel.approve(candidate: candidate)
                            NotificationCenter.default.post(
                                name: .sshStudioHostTrustApproved,
                                object: nil,
                                userInfo: ["endpointKey": candidate.endpoint.key]
                            )
                        } catch {
                            selectedOpen?.connectionService.hostIdentityFailed(error.localizedDescription)
                        }
                    }
                },
                onCancel: {
                    Task {
                        await hostKeyModel.cancel()
                        selectedOpen?.connectionService.hostIdentityFailed("Host verification cancelled.")
                    }
                },
                onOpenManager: {
                    showKnownHosts = true
                }
            )
        }
        .onKeyPress(.init("p"), phases: .down) { press in
            guard press.modifiers == [.command, .shift] else { return .ignored }
            showCommandPalette = true
            return .handled
        }
        .onKeyPress(.init("k"), phases: .down) { press in
            guard press.modifiers == [.command] else { return .ignored }
            showQuickConnect = true
            return .handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHStudioCommandPalette)) { _ in
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHStudioQuickConnect)) { _ in
            showQuickConnect = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHStudioKnownHosts)) { _ in
            showKnownHosts = true
        }
        .onChange(of: store.sessions) { _, sessions in
            refreshOpenSessions(from: sessions)
        }
    }

    private var hostKeyTrustSheetBinding: Binding<HostKeyTrustSheetItem?> {
        Binding(
            get: {
                hostKeyModel.pendingState.map { HostKeyTrustSheetItem(state: $0) }
            },
            set: { value in
                if value == nil {
                    Task { await hostKeyModel.cancel() }
                }
            }
        )
    }

    private func openOrSwitch(_ session: Session) {
        if let existing = openSessions.first(where: { $0.session.id == session.id }) {
            selectedOpenID = existing.id
            return
        }
        let open = OpenSession(session: session)
        openSessions.append(open)
        selectedOpenID = open.id
        ConnectionLog.shared.log("Opened session", level: .info, session: session.name)
    }

    private func closeSession(_ open: OpenSession) {
        openSessions.removeAll { $0.id == open.id }
        selectedOpenID = openSessions.last?.id
    }

    private func refreshOpenSessions(from sessions: [Session]) {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        openSessions.removeAll { sessionsByID[$0.session.id] == nil }
        for open in openSessions {
            if let updated = sessionsByID[open.session.id], updated != open.session {
                open.session = updated
            }
        }
        if !openSessions.contains(where: { $0.id == selectedOpenID }) {
            selectedOpenID = openSessions.last?.id
        }
    }
}

// MARK: - Session Tab Bar (Tahoe floating style)

struct SessionTabBar: View {
    let openSessions: [OpenSession]
    @Binding var selectedID: UUID?
    let onClose: (OpenSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(openSessions) { open in
                    SessionTabItem(
                        open: open,
                        isSelected: selectedID == open.id,
                        onSelect: { selectedID = open.id },
                        onClose: { onClose(open) }
                    )
                }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(StudioTheme.glassStroke, lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.09), radius: 5, y: 2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(.ultraThinMaterial.opacity(0.62))
    }
}

struct SessionTabItem: View {
    @ObservedObject var open: OpenSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isSelected ? StudioTheme.accent : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .animation(.spring(duration: 0.2), value: isSelected)

                Text(open.session.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 120)

                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered || isSelected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(StudioTheme.accent.opacity(0.38), lineWidth: 0.8)
                        }
                        .shadow(color: StudioTheme.accent.opacity(0.16), radius: 6, y: 2)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var appearance = AppAppearanceSettings.shared
    let openSessionIDs: [UUID]
    let onSelect: (Session) -> Void
    let onQuickConnect: () -> Void
    let onCommandPalette: () -> Void

    @State private var showAddSession = false
    @State private var editingSession: Session?
    @State private var searchText = ""

    var filtered: [Session] {
        searchText.isEmpty ? store.sessions
            : store.sessions.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.host.localizedCaseInsensitiveContains(searchText)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [StudioTheme.accent, StudioTheme.accentBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 34, height: 34)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("SSH Studio")
                        .font(.system(size: 15, weight: .bold))
                    Text("Secure workspace")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCommandPalette) {
                    Image(systemName: "command")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StudioTheme.glassStroke, lineWidth: 0.7)
                        }
                }
                .buttonStyle(.plain)
                .help("Command Palette  ⌘⇧P")
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: .green.opacity(0.55), radius: 4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // Quick Connect pill
            Button(action: onQuickConnect) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Quick Connect")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("⌘K")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(
                            colors: [StudioTheme.accent, StudioTheme.accentBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                }
                .foregroundStyle(.white)
                .shadow(color: StudioTheme.accent.opacity(0.22), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .tahoeMagnifyGlass(
                tint: StudioTheme.accent,
                cornerRadius: 14,
                scale: 1.035,
                lift: 0.5,
                response: 0.46,
                dampingFraction: 0.96
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 14))
                TextField("Search sessions…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(StudioTheme.glassStroke, lineWidth: 0.7)
                    }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // Sessions list
            List {
                if !filtered.isEmpty {
                    Section {
                        ForEach(filtered) { session in
                            SidebarSessionRow(
                                session: session,
                                isOpen: openSessionIDs.contains(session.id),
                                onSelect: { onSelect(session) }
                            )
                            .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                Button("Open") { onSelect(session) }
                                Button("Edit") { editingSession = session }
                                Button("Duplicate") {
                                    var copy = session
                                    copy.id = UUID()
                                    copy.name = session.name + " Copy"
                                    store.add(copy)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    store.delete(at: IndexSet(
                                        store.sessions.indices.filter { store.sessions[$0].id == session.id }
                                    ))
                                }
                            }
                        }
                    } header: {
                        Text("Saved Sessions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                } else {
                    ContentUnavailableView(
                        store.sessions.isEmpty ? "No Sessions" : "No Results",
                        systemImage: store.sessions.isEmpty ? "server.rack" : "magnifyingglass",
                        description: Text(store.sessions.isEmpty ? "Add a session to get started" : "Try a different search")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)

            // New session
            Divider().opacity(0.5)
            Button {
                showAddSession = true
            } label: {
                Label("New Session", systemImage: "plus.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .tahoeMagnifyGlass(
                tint: Color.accentColor,
                cornerRadius: 10,
                scale: 1.03,
                lift: 0.5,
                response: 0.46,
                dampingFraction: 0.96
            )

            Divider().opacity(0.5)
            Menu {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Button {
                        appearance.appearance = option
                    } label: {
                        if appearance.appearance == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Label(option.rawValue, systemImage: appearanceIcon(for: option))
                        }
                    }
                }
            } label: {
                HStack {
                    Label("Appearance", systemImage: appearanceIcon(for: appearance.appearance))
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                    Text(appearance.appearance.rawValue)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .menuStyle(.borderlessButton)
            .tahoeMagnifyGlass(
                tint: StudioTheme.accentBlue,
                cornerRadius: 10,
                scale: 1.03,
                lift: 0.5,
                response: 0.46,
                dampingFraction: 0.96
            )
            .padding(.horizontal, 2)
        }
        .background {
            ZStack {
                StudioBackdrop()
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showAddSession) { AddSessionView { store.add($0) } }
        .sheet(item: $editingSession) { s in
            AddSessionView(existing: s) { store.update($0) }
        }
    }

    private func appearanceIcon(for option: AppAppearance) -> String {
        switch option {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Sidebar Session Row

struct SidebarSessionRow: View {
    let session: Session
    let isOpen: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isOpen
                            ? LinearGradient(colors: [.accentColor, .accentColor.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color(.quaternarySystemFill), Color(.quaternarySystemFill)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 34, height: 34)
                    Image(systemName: isOpen ? "terminal.fill" : "server.rack")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isOpen ? .white : .secondary)
                }
                .shadow(color: isOpen ? .accentColor.opacity(0.3) : .clear, radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(session.username)@\(session.host)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isOpen {
                    Text("OPEN")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tahoeMagnifyGlass(
                isActive: isOpen,
                tint: isOpen ? .accentColor : StudioTheme.accentBlue,
                cornerRadius: 10,
                scale: 1.035,
                lift: 0.5,
                response: 0.46,
                dampingFraction: 0.96
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Detail Wrapper (observes OpenSession so tab changes re-render)

struct SessionDetailWrapper: View {
    @ObservedObject var open: OpenSession
    @ObservedObject var store: SessionStore
    @ObservedObject var sshManager: SSHManager

    var body: some View {
        SessionDetailView(
            session: Binding(
                get: { open.session },
                set: {
                    open.session = $0
                    store.update($0)
                }
            ),
            sshManager: sshManager,
            activeTab: $open.activeTab,
            sftpManager: open.sftpManager,
            connectionService: open.connectionService,
            sftpLocalHistory: open.sftpLocalHistory,
            allSessions: store.sessions
        )
    }
}

// MARK: - Session Detail

struct SessionDetailView: View {
    @Binding var session: Session
    @ObservedObject var sshManager: SSHManager
    @Binding var activeTab: SessionTab
    @ObservedObject var sftpManager: SFTPManager
    @ObservedObject var connectionService: SSHConnectionService
    @ObservedObject var sftpLocalHistory: NavigationHistory<URL>
    let allSessions: [Session]
    @State private var showTerminalSettings = false
    @State private var terminalInstanceID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(SessionTab.workspaceOrder, id: \.self) { tab in
                            Button { activeTab = tab } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(activeTab == tab ? tab.color : .secondary)
                                    Text(tab.rawValue)
                                        .font(.system(size: 12, weight: activeTab == tab ? .semibold : .regular))
                                        .foregroundStyle(activeTab == tab ? .primary : .secondary)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .tahoeMagnifyGlass(
                                    isActive: activeTab == tab,
                                    tint: tab.color,
                                    cornerRadius: 8,
                                    scale: 1.14,
                                    response: 0.48,
                                    dampingFraction: 0.95
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if activeTab == .terminal {
                    TerminalWorkspaceControls(showSettings: $showTerminalSettings)
                        .transition(.opacity)
                }
            }
            .padding(3)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(StudioTheme.glassStroke, lineWidth: 0.7)
            }
            .shadow(color: .black.opacity(0.09), radius: 5, y: 2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial.opacity(0.52))
            .sheet(isPresented: $showTerminalSettings) {
                TerminalSettingsView()
            }
            .onKeyPress(.init("f"), phases: .down) { press in
                guard press.modifiers == [.command, .shift] else { return .ignored }
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            }

            ZStack {
                                TerminalTabView(session: session)
                                    .environmentObject(connectionService)
                                    .environmentObject(HostKeyVerificationModel.shared)
                    .id(terminalInstanceID)
                    .opacity(activeTab == .terminal ? 1 : 0)
                    .allowsHitTesting(activeTab == .terminal)
                    .zIndex(activeTab == .terminal ? 1 : 0)

                SFTPBrowserView(
                    session: session,
                    sftp: sftpManager,
                    localHistory: sftpLocalHistory,
                    allSessions: allSessions,
                    isActive: activeTab == .sftp
                )
                .opacity(activeTab == .sftp ? 1 : 0)
                .allowsHitTesting(activeTab == .sftp)
                .zIndex(activeTab == .sftp ? 1 : 0)

                if !isPersistentTab(activeTab) {
                    Group {
                        switch activeTab {
                        case .terminal, .sftp:
                            EmptyView()
                        case .screen:
                            ScreenSharingView(session: session)
                        case .tunnels:
                            PortForwardingView(session: $session, sshManager: sshManager)
                        case .sync:
                            SyncView(session: session, allSessions: allSessions)
                        case .transfers:
                            TransferConsoleView()
                        case .keys:
                            KeyManagerView()
                        }
                    }
                    .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: .sshStudioHostTrustApproved)) { note in
                guard let endpointKey = note.userInfo?["endpointKey"] as? String,
                      endpointKey == SSHHostEndpoint(session: session).key else { return }
                terminalInstanceID = UUID()
            }

            StatusBarView(
                session: session,
                connectionService: connectionService,
                onReconnect: {
                    terminalInstanceID = UUID()
                },
                onCancelReconnect: {
                    connectionService.cancelReconnect()
                }
            )
        }
    }

    private func isPersistentTab(_ tab: SessionTab) -> Bool {
        tab == .terminal || tab == .sftp
    }
}

private struct TerminalWorkspaceControls: View {
    @ObservedObject private var settings = TerminalSettings.shared
    @Binding var showSettings: Bool
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: 1) {
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 22, height: 22)
            }
            .help("Terminal Settings")

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)

            Button {
                settings.fontSize = max(10, settings.fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 22, height: 22)
            }
            .help("Decrease Text Size")

            Button {
                settings.fontSize = min(36, settings.fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 22, height: 22)
            }
            .help("Increase Text Size")

            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .frame(width: 22, height: 22)
            }
            .help(isFullScreen ? "Exit Full Screen  Cmd-Shift-F" : "Full Screen  Cmd-Shift-F")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.65), in: Capsule())
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    let session: Session
    @ObservedObject var connectionService: SSHConnectionService
    var onReconnect: () -> Void = {}
    var onCancelReconnect: () -> Void = {}
    @ObservedObject var queue = TransferQueue.shared
    @ObservedObject var log = ConnectionLog.shared

    var lastLog: LogEntry? { log.entries.first { $0.session == session.name } }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(connectionColor).frame(width: 5, height: 5)
                Text(connectionLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                if let detail = connectionState.safeDetail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if showsReconnect {
                    Button {
                        onReconnect()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Reconnect")
                }
                if case .reconnecting = connectionState {
                    Button {
                        onCancelReconnect()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel reconnect")
                }
            }

            if queue.activeCount > 0 {
                Divider().frame(height: 10)
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    Text("\(queue.activeCount) active")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let entry = lastLog {
                Text(entry.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(session.host)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial.opacity(0.75))
    }

    private var connectionState: SSHConnectionState {
        connectionService.state
    }

    private var connectionLabel: String {
        connectionState.displayLabel
    }

    private var connectionColor: Color {
        switch connectionState {
        case .connected: return .green
        case .connecting, .preparing, .checkingHostIdentity, .authenticating, .awaitingHostVerification, .reconnecting: return .orange
        case .failed: return .red
        case .disconnecting: return .yellow
        case .idle, .disconnected: return .secondary
        }
    }

    private var showsReconnect: Bool {
        switch connectionState {
        case .disconnected, .failed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Quick Connect

struct QuickConnectView: View {
    @Environment(\.dismiss) var dismiss
    var onConnect: (Session) -> Void

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var alias = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Color.accentColor)
                }
                Text("Quick Connect")
                    .font(.title3.bold())
                Text("Connect to any SSH server instantly")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider().opacity(0.5)

            Form {
                LabeledContent("Host") {
                    TextField("hostname or IP", text: $host)
                }
                LabeledContent("Port") {
                    TextField("22", text: $port)
                        .frame(width: 60)
                }
                LabeledContent("Username") {
                    TextField("username", text: $username)
                }
                LabeledContent("Alias") {
                    TextField("~/.ssh/config alias (optional)", text: $alias)
                }
                if let validationMessage {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider().opacity(0.5)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Connect") {
                    let session = Session(
                        name: alias.isEmpty ? host : alias,
                        host: host,
                        port: Int(port) ?? 22,
                        username: username,
                        sshConfigAlias: alias
                    )
                    onConnect(session)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(validationMessage != nil)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private var validationMessage: String? {
        do {
            try SSHSecurity.validate(session: Session(
                name: alias.isEmpty ? host : alias,
                host: host,
                port: Int(port) ?? 0,
                username: username,
                sshConfigAlias: alias
            ))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var onQuickConnect: () -> Void

    var body: some View {
        ZStack {
            StudioBackdrop()

            VStack(spacing: 28) {
                // Hero
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(StudioTheme.accent.opacity(0.08))
                            .frame(width: 160, height: 160)
                            .blur(radius: 12)
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 104, height: 104)
                            .overlay {
                                Circle()
                                    .strokeBorder(StudioTheme.accent.opacity(0.25), lineWidth: 1)
                            }
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(LinearGradient(
                                colors: [StudioTheme.accent, StudioTheme.accentBlue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    }

                    VStack(spacing: 6) {
                        Text("SSH Studio")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("A secure command center for remote systems")
                            .foregroundStyle(.secondary)
                    }
                }

                // Action
                VStack(spacing: 10) {
                    Button(action: onQuickConnect) {
                        Label("Start a Secure Session", systemImage: "bolt.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 220)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("k", modifiers: .command)

                    Text("⌘K  or choose a saved workspace from the sidebar")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                // Feature cards
                HStack(spacing: 12) {
                    FeatureCard(icon: "lock.shield.fill", color: StudioTheme.accent, title: "Hardened SSH", desc: "macOS OpenSSH\nsecurity policy")
                    FeatureCard(icon: "folder.fill", color: StudioTheme.accentBlue, title: "File Studio", desc: "Fast drag & drop\ntransfers")
                    FeatureCard(icon: "point.3.connected.trianglepath.dotted", color: StudioTheme.accentPurple, title: "Tunnels", desc: "Forward ports\nand proxies")
                    FeatureCard(icon: "arrow.triangle.2.circlepath", color: .orange, title: "Sync Engine", desc: "Mirror folders\nwith rsync")
                }

                HStack(spacing: 16) {
                    WelcomeBadge(icon: "checkmark.shield.fill", text: "Hardened runtime")
                    WelcomeBadge(icon: "key.fill", text: "Key authentication")
                    WelcomeBadge(icon: "arrow.down.circle.fill", text: "Verified updates")
                }
            }
            .padding(40)
        }
    }
}

struct FeatureCard: View {
    let icon: String
    let color: Color
    let title: String
    let desc: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(desc)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 128)
        .padding(.horizontal, 13)
        .padding(.vertical, 15)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(color.opacity(0.18), lineWidth: 1)
                }
        }
    }
}

struct WelcomeBadge: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}
