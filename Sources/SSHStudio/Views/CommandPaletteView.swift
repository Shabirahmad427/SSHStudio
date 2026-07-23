import SwiftUI

struct CommandPaletteView: View {
    let sessions: [Session]
    let hasOpenSession: Bool
    let onQuickConnect: () -> Void
    let onOpenSession: (Session) -> Void
    let onSelectTool: (SessionTab) -> Void
    let onTerminalSettings: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands and sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if filteredItems.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .padding(.top, 28)
                    } else {
                        ForEach(filteredItems) { item in
                            Button {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    item.action()
                                }
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(item.color)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(.primary)
                                        if let subtitle = item.subtitle {
                                            Text(subtitle)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }

                                    Spacer()

                                    if let shortcut = item.shortcut {
                                        Text(shortcut)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 540, height: 480)
    }

    private var filteredItems: [PaletteItem] {
        let items = commandItems + sessionItems
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
                ($0.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var commandItems: [PaletteItem] {
        var items = [
            PaletteItem(
                title: "Quick Connect",
                subtitle: "Open a new SSH connection",
                icon: "bolt.fill",
                color: StudioTheme.accent,
                shortcut: "⌘K",
                action: onQuickConnect
            ),
            PaletteItem(
                title: "Terminal Settings",
                subtitle: "Fonts, themes, and terminal appearance",
                icon: "slider.horizontal.3",
                color: StudioTheme.accentBlue,
                action: onTerminalSettings
            )
        ]

        if hasOpenSession {
            items += SessionTab.workspaceOrder.map { tab in
                PaletteItem(
                    title: "Show \(tab.rawValue)",
                    subtitle: "Switch the active workspace tool",
                    icon: tab.icon,
                    color: tab.color,
                    action: { onSelectTool(tab) }
                )
            }
        }
        return items
    }

    private var sessionItems: [PaletteItem] {
        sessions.map { session in
            PaletteItem(
                title: "Open \(session.name)",
                subtitle: "\(session.username)@\(session.host):\(session.port)",
                icon: "server.rack",
                color: StudioTheme.accent,
                action: { onOpenSession(session) }
            )
        }
    }
}

private struct PaletteItem: Identifiable {
    let id = UUID()
    let title: String
    var subtitle: String? = nil
    let icon: String
    let color: Color
    var shortcut: String? = nil
    let action: () -> Void
}
