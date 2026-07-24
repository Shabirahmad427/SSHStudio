import SwiftUI

struct AppShellView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var sshManager: SSHManager
    @ObservedObject var hostKeyModel: HostKeyVerificationModel
    @Binding var openSessions: [OpenSession]
    @Binding var selectedOpenID: UUID?
    @Binding var showQuickConnect: Bool
    @Binding var showCommandPalette: Bool
    @Binding var showTerminalSettings: Bool
    @Binding var showKnownHosts: Bool

    @AppStorage("app_shell_column_visibility") private var storedColumnVisibility = "all"
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showAddSession = false

    var selectedOpen: OpenSession? {
        openSessions.first { $0.id == selectedOpenID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                store: store,
                openSessions: openSessions,
                selectedOpenID: selectedOpenID,
                onSelect: openOrSwitch,
                onQuickConnect: { showQuickConnect = true },
                onCommandPalette: { showCommandPalette = true },
                onNewConnection: { showAddSession = true }
            )
            .navigationSplitViewColumnWidth(
                min: SSHStudioMetrics.sidebarMinWidth,
                ideal: SSHStudioMetrics.sidebarIdealWidth,
                max: SSHStudioMetrics.sidebarMaxWidth
            )
        } detail: {
            WorkspaceView(
                store: store,
                sshManager: sshManager,
                openSessions: openSessions,
                selectedOpenID: $selectedOpenID,
                onClose: closeSession,
                onDuplicate: duplicateSession,
                onQuickConnect: { showQuickConnect = true }
            )
            .background(SSHStudioColors.windowBackground)
        }
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear {
            columnVisibility = storedColumnVisibility == "detailOnly" ? .detailOnly : .all
        }
        .onChange(of: columnVisibility) { _, visibility in
            storedColumnVisibility = visibility == .detailOnly ? "detailOnly" : "all"
        }
        .onChange(of: store.sessions) { _, sessions in
            refreshOpenSessions(from: sessions)
        }
        .sheet(isPresented: $showAddSession) { AddSessionView { store.add($0) } }
        .onReceive(NotificationCenter.default.publisher(for: .showSSHStudioNewConnection)) { _ in
            showAddSession = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSSHStudioSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: .duplicateSSHStudioActiveTab)) { _ in
            guard let selectedOpen else { return }
            duplicateSession(selectedOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeSSHStudioActiveTab)) { _ in
            guard let selectedOpen else { return }
            closeSession(selectedOpen)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSSHStudioNextTab)) { _ in
            selectOpenSession(offset: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSSHStudioPreviousTab)) { _ in
            selectOpenSession(offset: -1)
        }
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
        if selectedOpenID == open.id {
            selectedOpenID = openSessions.last?.id
        }
    }

    private func duplicateSession(_ open: OpenSession) {
        let duplicate = OpenSession(session: open.session)
        duplicate.activeTab = open.activeTab
        openSessions.append(duplicate)
        selectedOpenID = duplicate.id
        ConnectionLog.shared.log("Duplicated workspace tab", level: .info, session: open.session.name)
    }

    private func selectOpenSession(offset: Int) {
        guard !openSessions.isEmpty else { return }
        let currentIndex = selectedOpenID.flatMap { id in openSessions.firstIndex { $0.id == id } } ?? 0
        let nextIndex = (currentIndex + offset + openSessions.count) % openSessions.count
        selectedOpenID = openSessions[nextIndex].id
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
