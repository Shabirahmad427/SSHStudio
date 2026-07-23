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
                onCommandPalette: { showCommandPalette = true }
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
