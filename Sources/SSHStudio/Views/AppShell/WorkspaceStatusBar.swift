import SwiftUI

struct WorkspaceStatusBar: View {
    let session: Session
    @ObservedObject var connectionService: SSHConnectionService
    var onReconnect: () -> Void
    var onDisconnect: () -> Void
    var onCancelReconnect: () -> Void
    @ObservedObject private var queue = TransferQueue.shared
    @ObservedObject private var log = ConnectionLog.shared

    private var style: SSHStudioStatusStyle {
        SSHStudioStatusStyle.connection(connectionService.state)
    }

    private var lastLog: LogEntry? {
        log.entries.first { $0.session == session.name }
    }

    var body: some View {
        HStack(spacing: SSHStudioSpacing.sm) {
            SSHStatusPill(style: style)
            if let detail = connectionService.state.safeDetail {
                Text(detail)
                    .font(SSHStudioTypography.status)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            reconnectControls
            disconnectControl

            if queue.activeCount > 0 {
                Divider().frame(height: 12)
                Label("\(queue.activeCount) transfer active", systemImage: "arrow.up.arrow.down")
                    .font(SSHStudioTypography.status)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let entry = lastLog {
                Text(entry.message)
                    .font(SSHStudioTypography.status)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Text(SSHHostEndpoint(session: session).displayName)
                .font(SSHStudioTypography.metadata)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, SSHStudioSpacing.md)
        .frame(height: 26)
        .background(.bar)
    }

    @ViewBuilder
    private var reconnectControls: some View {
        switch connectionService.state {
        case .disconnected, .failed:
            Button(action: onReconnect) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Reconnect")
        case .reconnecting:
            Button(action: onCancelReconnect) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Cancel Reconnect")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var disconnectControl: some View {
        if connectionService.state.isActive {
            Button(action: onDisconnect) {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.plain)
            .help("Disconnect")
        }
    }
}
