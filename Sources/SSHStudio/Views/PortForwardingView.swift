import SwiftUI

struct PortForwardingView: View {
    @Binding var session: Session
    @ObservedObject var sshManager: SSHManager
    @State private var showAddTunnel = false
    @State private var editingTunnel: TunnelConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Port Forwarding")
                    .font(.headline)
                Spacer()
                Button {
                    showAddTunnel = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .padding()

            Divider()

            if session.tunnels.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No tunnels configured")
                        .foregroundStyle(.secondary)
                    Button("Add Tunnel") { showAddTunnel = true }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach($session.tunnels) { $tunnel in
                        TunnelRow(tunnel: $tunnel, session: session, sshManager: sshManager)
                            .contextMenu {
                                Button("Edit") { editingTunnel = tunnel }
                                Button("Delete", role: .destructive) {
                                    sshManager.stopTunnel(id: tunnel.id)
                                    session.tunnels.removeAll { $0.id == tunnel.id }
                                }
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddTunnel) {
            TunnelEditView(tunnel: TunnelConfig()) { newTunnel in
                session.tunnels.append(newTunnel)
            }
        }
        .sheet(item: $editingTunnel) { tunnel in
            TunnelEditView(tunnel: tunnel) { updated in
                if let idx = session.tunnels.firstIndex(where: { $0.id == updated.id }) {
                    session.tunnels[idx] = updated
                }
            }
        }
    }
}

struct TunnelRow: View {
    @Binding var tunnel: TunnelConfig
    let session: Session
    @ObservedObject var sshManager: SSHManager

    var isActive: Bool { sshManager.isTunnelActive(tunnel.id) }
    var isEnabled: Bool { sshManager.isTunnelEnabled(tunnel.id) }
    var isReconnecting: Bool { sshManager.isTunnelReconnecting(tunnel.id) }
    var error: String? { sshManager.tunnelError(tunnel.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isActive ? Color.green : (isReconnecting ? Color.orange : Color.gray))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.name.isEmpty ? "Tunnel" : tunnel.name)
                    .font(.headline)
                Group {
                    switch tunnel.type {
                    case .local:
                        Text("\(tunnel.listenHost):\(tunnel.localPort) → \(tunnel.remoteHost):\(tunnel.remotePort)")
                    case .remote:
                        Text("Remote \(tunnel.listenHost):\(tunnel.remotePort) → \(tunnel.remoteHost):\(tunnel.localPort)")
                    case .dynamic:
                        Text("SOCKS5 proxy on \(tunnel.listenHost):\(tunnel.localPort)")
                    }
                }
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)

                if isReconnecting {
                    Text("Reconnecting…")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(tunnel.type.rawValue)
                .font(.footnote)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .cornerRadius(4)

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { on in
                    if on { sshManager.startTunnel(tunnel: tunnel, session: session) }
                    else { sshManager.stopTunnel(id: tunnel.id) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

struct TunnelEditView: View {
    @State var tunnel: TunnelConfig
    var onSave: (TunnelConfig) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(tunnel.name.isEmpty ? "New Tunnel" : tunnel.name)
                .font(.headline)
                .padding()

            Divider()

            Form {
                TextField("Name", text: $tunnel.name)
                Picker("Type", selection: $tunnel.type) {
                    ForEach(TunnelConfig.TunnelType.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }

                if tunnel.type != .dynamic {
                    LabeledContent("Local Port") {
                        TextField("", value: $tunnel.localPort, format: .number)
                            .frame(width: 80)
                    }
                    TextField("Remote Host", text: $tunnel.remoteHost)
                    LabeledContent("Remote Port") {
                        TextField("", value: $tunnel.remotePort, format: .number)
                            .frame(width: 80)
                    }
                } else {
                    LabeledContent("SOCKS Port") {
                        TextField("", value: $tunnel.localPort, format: .number)
                            .frame(width: 80)
                    }
                }

                Section("Listener") {
                    TextField("Listen Interface", text: $tunnel.listenHost)
                    Text("Use 127.0.0.1 for local-only access. Use 0.0.0.0 only when other devices must connect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Reconnect automatically", isOn: $tunnel.autoReconnect)
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    onSave(tunnel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 380)
    }

    private var isValid: Bool {
        guard !tunnel.listenHost.isEmpty, (1...65535).contains(tunnel.localPort) else { return false }
        return tunnel.type == .dynamic || (!tunnel.remoteHost.isEmpty && (1...65535).contains(tunnel.remotePort))
    }
}
