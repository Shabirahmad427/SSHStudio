import SwiftUI

struct SessionTabBar: View {
    let openSessions: [OpenSession]
    @Binding var selectedID: UUID?
    let onClose: (OpenSession) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SSHStudioSpacing.xs) {
                ForEach(openSessions) { open in
                    SessionTabItem(
                        open: open,
                        connectionService: open.connectionService,
                        isSelected: selectedID == open.id,
                        onSelect: { selectedID = open.id },
                        onClose: { onClose(open) }
                    )
                }
            }
            .padding(.horizontal, SSHStudioSpacing.sm)
            .padding(.vertical, SSHStudioSpacing.xs)
        }
        .background(SSHStudioColors.paneBackground)
    }
}

private struct SessionTabItem: View {
    @ObservedObject var open: OpenSession
    @ObservedObject var connectionService: SSHConnectionService
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: SSHStudioSpacing.xs) {
                SSHConnectionStatusPill(service: connectionService, showsTitle: false)
                Text(open.session.name)
                    .font(isSelected ? SSHStudioTypography.bodyEmphasis : SSHStudioTypography.body)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .opacity(hovered || isSelected ? 1 : 0)
                .help("Close Tab")
            }
            .padding(.horizontal, SSHStudioSpacing.sm)
            .frame(height: 28)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : SSHStudioColors.separator.opacity(hovered ? 0.7 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: SSHStudioMetrics.controlCornerRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(open.session.name), \(SSHStudioStatusStyle.connection(connectionService.state).title)")
    }
}
