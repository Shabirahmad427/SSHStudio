import SwiftUI
import AppKit

struct InspectorView: View {
    @ObservedObject var open: OpenSession
    @ObservedObject var connectionService: SSHConnectionService
    @ObservedObject private var log = ConnectionLog.shared
    @State private var showConnection = true
    @State private var showSecurity = true
    @State private var showTunnels = true
    @State private var showDiagnostics = true

    private var endpoint: SSHHostEndpoint {
        SSHHostEndpoint(session: open.session)
    }

    var body: some View {
        Form {
            DisclosureGroup("Connection", isExpanded: $showConnection) {
                LabeledContent("Profile", value: open.session.name)
                LabeledContent("Endpoint", value: DiagnosticRedactor.redact(endpoint.displayName))
                LabeledContent("Workspace", value: open.activeTab.rawValue)
                LabeledContent("State") {
                    SSHConnectionStatusPill(service: connectionService)
                }
                if let detail = connectionService.state.safeDetail {
                    LabeledContent("Detail", value: detail)
                }
                if let timestamp = stateTimestamp {
                    LabeledContent("Updated") {
                        Text(timestamp, style: .time)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup("Security", isExpanded: $showSecurity) {
                LabeledContent("Host-Key Policy", value: "Explicit verification")
                LabeledContent("Trust Source", value: "OpenSSH / SSH Studio")
                LabeledContent("Known hosts") {
                    Button("Manage") {
                        NotificationCenter.default.post(name: .showSSHStudioKnownHosts, object: nil)
                    }
                }
                Text("Credential values are never shown here.")
                    .font(SSHStudioTypography.metadata)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Tunnels", isExpanded: $showTunnels) {
                if open.session.tunnels.isEmpty {
                    Text("No saved tunnels")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(open.session.tunnels) { tunnel in
                        LabeledContent(tunnel.name.isEmpty ? tunnel.type.rawValue : tunnel.name) {
                            Text("\(tunnel.listenHost):\(tunnel.localPort)")
                                .font(SSHStudioTypography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                let entries = log.entries.filter { $0.session == open.session.name }.prefix(6)
                if entries.isEmpty && connectionService.events.isEmpty {
                    Text("No recent diagnostics")
                        .foregroundStyle(.secondary)
                }
                ForEach(connectionService.events.prefix(4)) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.message)
                            .lineLimit(2)
                        Text(event.timestamp, style: .time)
                            .font(SSHStudioTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .lineLimit(2)
                        Text(entry.timestamp, style: .time)
                            .font(SSHStudioTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Copy Safe Summary") {
                    copySafeSummary()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SSHStudioColors.paneBackground)
    }

    private var stateTimestamp: Date? {
        switch connectionService.state {
        case .preparing(let date), .connecting(let date), .connected(let date),
             .disconnected(let date, _), .failed(let date, _):
            return date
        case .reconnecting(_, let next):
            return next
        default:
            return nil
        }
    }

    private func copySafeSummary() {
        let summary = [
            "Profile: \(open.session.name)",
            "State: \(connectionService.state.displayLabel)",
            "Workspace: \(open.activeTab.rawValue)"
        ].joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticRedactor.redact(summary), forType: .string)
    }
}
