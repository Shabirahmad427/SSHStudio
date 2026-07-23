import SwiftUI

struct InspectorView: View {
    @ObservedObject var open: OpenSession
    @ObservedObject private var log = ConnectionLog.shared

    private var endpoint: SSHHostEndpoint {
        SSHHostEndpoint(session: open.session)
    }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Profile", value: open.session.name)
                LabeledContent("Endpoint", value: endpoint.displayName)
                LabeledContent("State") {
                    SSHStatusPill(style: SSHStudioStatusStyle.connection(open.connectionService.state))
                }
            }

            Section("Security") {
                LabeledContent("Host key policy", value: "OpenSSH verified")
                LabeledContent("Known hosts") {
                    Button("Manage") {
                        NotificationCenter.default.post(name: .showSSHStudioKnownHosts, object: nil)
                    }
                }
                Text("Credential values are never shown here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Tunnels") {
                if open.session.tunnels.isEmpty {
                    Text("No saved tunnels")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(open.session.tunnels.count) configured")
                }
            }

            Section("Diagnostics") {
                ForEach(log.entries.filter { $0.session == open.session.name }.prefix(4)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .lineLimit(2)
                        Text(entry.timestamp, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(SSHStudioColors.paneBackground)
    }
}
