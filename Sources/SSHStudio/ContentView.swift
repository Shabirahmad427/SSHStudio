import SwiftUI

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

    private var selectedOpen: OpenSession? {
        openSessions.first { $0.id == selectedOpenID }
    }

    var body: some View {
        AppShellView(
            store: store,
            sshManager: sshManager,
            hostKeyModel: hostKeyModel,
            openSessions: $openSessions,
            selectedOpenID: $selectedOpenID,
            showQuickConnect: $showQuickConnect,
            showCommandPalette: $showCommandPalette,
            showTerminalSettings: $showTerminalSettings,
            showKnownHosts: $showKnownHosts
        )
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
}
