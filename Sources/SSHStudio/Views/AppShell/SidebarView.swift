import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    let openSessions: [OpenSession]
    let selectedOpenID: UUID?
    let onSelect: (Session) -> Void
    let onQuickConnect: () -> Void
    let onCommandPalette: () -> Void

    @ObservedObject private var appearance = AppAppearanceSettings.shared
    @State private var showAddSession = false
    @State private var editingSession: Session?
    @State private var searchText = ""

    private var filteredSessions: [Session] {
        guard !searchText.isEmpty else { return store.sessions }
        return store.sessions.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.host.localizedCaseInsensitiveContains(searchText)
                || $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader
            quickActions
            searchField
            sessionList
            footer
        }
        .background(SSHStudioColors.sidebarBackground)
        .sheet(isPresented: $showAddSession) { AddSessionView { store.add($0) } }
        .sheet(item: $editingSession) { session in
            AddSessionView(existing: session) { store.update($0) }
        }
    }

    private var sidebarHeader: some View {
        HStack(spacing: SSHStudioSpacing.sm) {
            Image(systemName: "terminal")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("SSH Studio")
                    .font(SSHStudioTypography.sidebarTitle)
                Text("Native SSH client")
                    .font(SSHStudioTypography.sidebarSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCommandPalette) {
                Image(systemName: "command")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Command Palette")
        }
        .padding(.horizontal, SSHStudioSpacing.md)
        .padding(.vertical, SSHStudioSpacing.md)
    }

    private var quickActions: some View {
        HStack(spacing: SSHStudioSpacing.sm) {
            Button(action: onQuickConnect) {
                Label("Quick Connect", systemImage: "bolt")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                showAddSession = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("New Connection")
        }
        .padding(.horizontal, SSHStudioSpacing.md)
        .padding(.bottom, SSHStudioSpacing.sm)
    }

    private var searchField: some View {
        HStack(spacing: SSHStudioSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(SSHStudioTypography.body)
        .padding(.horizontal, SSHStudioSpacing.sm)
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius)
                .strokeBorder(SSHStudioColors.separator.opacity(0.45), lineWidth: 1)
        }
        .padding(.horizontal, SSHStudioSpacing.md)
        .padding(.bottom, SSHStudioSpacing.sm)
    }

    private var sessionList: some View {
        List(selection: .constant(selectedOpenID)) {
            Section("Saved Hosts") {
                if filteredSessions.isEmpty {
                    Text(store.sessions.isEmpty ? "No saved hosts" : "No matching hosts")
                        .font(SSHStudioTypography.body)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, SSHStudioSpacing.sm)
                } else {
                    ForEach(filteredSessions) { session in
                        let open = openSessions.first { $0.session.id == session.id }
                        SidebarSessionRow(
                            session: session,
                            open: open,
                            isSelected: open?.id == selectedOpenID,
                            isOpen: open != nil,
                            onSelect: { onSelect(session) }
                        )
                        .tag(open?.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                        .contextMenu {
                            Button("Connect") { onSelect(session) }
                            Button("Edit") { editingSession = session }
                            Button("Duplicate") {
                                var copy = session
                                copy.id = UUID()
                                copy.name = "\(session.name) Copy"
                                store.add(copy)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                store.delete(at: IndexSet(store.sessions.indices.filter { store.sessions[$0].id == session.id }))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Menu {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Button {
                        appearance.appearance = option
                    } label: {
                        Label(option.rawValue, systemImage: appearance.appearance == option ? "checkmark" : appearanceIcon(for: option))
                    }
                }
            } label: {
                HStack {
                    Label("Appearance", systemImage: appearanceIcon(for: appearance.appearance))
                    Spacer()
                    Text(appearance.appearance.rawValue)
                        .foregroundStyle(.secondary)
                }
                .font(SSHStudioTypography.body)
                .padding(.horizontal, SSHStudioSpacing.md)
                .padding(.vertical, SSHStudioSpacing.sm)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private func appearanceIcon(for option: AppAppearance) -> String {
        switch option {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

private struct SidebarSessionRow: View {
    let session: Session
    let open: OpenSession?
    let isSelected: Bool
    let isOpen: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: SSHStudioSpacing.sm) {
                Image(systemName: isOpen ? "terminal.fill" : "server.rack")
                    .foregroundStyle(isOpen ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .font(SSHStudioTypography.bodyEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(session.username)@\(session.host)")
                        .font(SSHStudioTypography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: SSHStudioSpacing.sm)
                if let open {
                    SSHConnectionStatusPill(service: open.connectionService, showsTitle: true)
                } else {
                    SSHStatusPill(style: SSHStudioStatusStyle.connection(.idle), showsTitle: true)
                }
            }
            .frame(minHeight: SSHStudioMetrics.regularRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.name), \(SSHStudioStatusStyle.connection(open?.connectionService.state ?? .idle).title)")
    }
}
