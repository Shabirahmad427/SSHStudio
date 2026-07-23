import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var sshManager: SSHManager
    let openSessions: [OpenSession]
    @Binding var selectedOpenID: UUID?
    let onClose: (OpenSession) -> Void
    let onQuickConnect: () -> Void

    @AppStorage("app_shell_inspector_visible") private var inspectorVisible = true

    private var selectedOpen: OpenSession? {
        openSessions.first { $0.id == selectedOpenID }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(
                open: selectedOpen,
                inspectorVisible: $inspectorVisible,
                onQuickConnect: onQuickConnect
            )
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if !openSessions.isEmpty {
                        SessionTabBar(
                            openSessions: openSessions,
                            selectedID: $selectedOpenID,
                            onClose: onClose
                        )
                        Divider()
                    }
                    workspaceContent
                }
                if inspectorVisible, let selectedOpen {
                    Divider()
                    InspectorView(open: selectedOpen, connectionService: selectedOpen.connectionService)
                        .frame(
                            minWidth: SSHStudioMetrics.inspectorMinWidth,
                            idealWidth: SSHStudioMetrics.inspectorIdealWidth,
                            maxWidth: SSHStudioMetrics.inspectorMaxWidth
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if openSessions.isEmpty {
            EmptyWorkspaceView(onQuickConnect: onQuickConnect)
        } else {
            ZStack {
                ForEach(openSessions) { open in
                    let isSelected = selectedOpenID == open.id
                    SessionDetailWrapper(open: open, store: store, sshManager: sshManager)
                        .opacity(isSelected ? 1 : 0)
                        .allowsHitTesting(isSelected)
                        .zIndex(isSelected ? 1 : 0)
                }
            }
        }
    }
}

struct WorkspaceToolbar: View {
    @ObservedObject private var terminalSettings = TerminalSettings.shared
    let open: OpenSession?
    @Binding var inspectorVisible: Bool
    let onQuickConnect: () -> Void

    var body: some View {
        HStack(spacing: SSHStudioSpacing.sm) {
            Button(action: onQuickConnect) {
                Label("Quick Connect", systemImage: "bolt")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("Quick Connect")

            if let open {
                WorkspaceToolbarSessionControls(open: open, connectionService: open.connectionService)
            }

            Spacer()

            Button {
                terminalSettings.fontSize = max(10, terminalSettings.fontSize - 1)
            } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .help("Decrease Terminal Font")

            Button {
                terminalSettings.fontSize = min(36, terminalSettings.fontSize + 1)
            } label: {
                Image(systemName: "textformat.size.larger")
            }
            .help("Increase Terminal Font")

            Button {
                inspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle Inspector")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, SSHStudioSpacing.md)
        .padding(.vertical, SSHStudioSpacing.sm)
        .background(.bar)
    }
}

private struct WorkspaceToolbarSessionControls: View {
    @ObservedObject var open: OpenSession
    @ObservedObject var connectionService: SSHConnectionService

    var body: some View {
        Picker("Workspace", selection: $open.activeTab) {
            ForEach(SessionTab.workspaceOrder, id: \.self) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)

        SSHConnectionStatusPill(service: connectionService)
            .padding(.leading, SSHStudioSpacing.xs)
    }
}

struct EmptyWorkspaceView: View {
    let onQuickConnect: () -> Void

    var body: some View {
        SSHStudioEmptyState(
            title: "No Workspace Open",
            message: "Choose a saved host or start a temporary connection.",
            systemImage: "terminal",
            actionTitle: "Quick Connect",
            action: onQuickConnect
        )
    }
}

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

struct SessionDetailView: View {
    @Binding var session: Session
    @ObservedObject var sshManager: SSHManager
    @Binding var activeTab: SessionTab
    @ObservedObject var sftpManager: SFTPManager
    @ObservedObject var connectionService: SSHConnectionService
    @ObservedObject var sftpLocalHistory: NavigationHistory<URL>
    let allSessions: [Session]
    @State private var terminalInstanceID = UUID()

    var body: some View {
        VStack(spacing: 0) {
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

            WorkspaceStatusBar(
                session: session,
                connectionService: connectionService,
                onReconnect: { terminalInstanceID = UUID() },
                onCancelReconnect: { connectionService.cancelReconnect() }
            )
        }
    }

    private func isPersistentTab(_ tab: SessionTab) -> Bool {
        tab == .terminal || tab == .sftp
    }
}
