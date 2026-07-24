import SwiftUI
import AppKit

struct AddSessionView: View {
    @Environment(\.dismiss) private var dismiss
    private let existing: Session?
    private let onSave: (Session) -> Void

    @State private var name: String
    @State private var host: String
    @State private var port: Int
    @State private var username: String
    @State private var authMethod: Session.AuthMethod
    @State private var privateKeyPath: String
    @State private var sshConfigAlias: String
    @State private var credentialReferenceID: String
    @State private var remoteStartDirectory: String
    @State private var remoteDirectory: String
    @State private var screenSharingHost: String
    @State private var screenSharingPort: Int
    @State private var remoteScreenMode: Session.RemoteScreenMode
    @State private var remoteAccessAddress: String
    @State private var tunnels: [TunnelConfig]
    @State private var favorite: Bool
    @State private var group: String

    init(existing: Session? = nil, onSave: @escaping (Session) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.host ?? "")
        _port = State(initialValue: existing?.port ?? 22)
        _username = State(initialValue: existing?.username ?? NSUserName())
        _authMethod = State(initialValue: existing?.authMethod ?? .password)
        _privateKeyPath = State(initialValue: existing?.privateKeyPath ?? "")
        _sshConfigAlias = State(initialValue: existing?.sshConfigAlias ?? "")
        _credentialReferenceID = State(initialValue: existing?.credentialReferenceID ?? "")
        _remoteStartDirectory = State(initialValue: existing?.remoteStartDirectory ?? existing?.remoteDirectory ?? "")
        _remoteDirectory = State(initialValue: existing?.remoteDirectory ?? "")
        _screenSharingHost = State(initialValue: existing?.screenSharingHost ?? "")
        _screenSharingPort = State(initialValue: existing?.screenSharingPort ?? 5900)
        _remoteScreenMode = State(initialValue: existing?.remoteScreenMode ?? .sshTunnel)
        _remoteAccessAddress = State(initialValue: existing?.remoteAccessAddress ?? "")
        _tunnels = State(initialValue: existing?.tunnels ?? [])
        _favorite = State(initialValue: existing?.favorite ?? false)
        _group = State(initialValue: existing?.group ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                generalSection
                authenticationSection
                securitySection
                networkSection
                terminalSection
                tunnelsSection
                remoteScreenSection
                advancedSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(SSHStudioColors.windowBackground)
            Divider()
            footer
        }
        .frame(width: 720, height: 680)
        .background(SSHStudioColors.windowBackground)
    }

    private var header: some View {
        HStack(spacing: SSHStudioSpacing.md) {
            Image(systemName: existing == nil ? "plus.circle" : "pencil.circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(existing == nil ? "New Connection" : "Edit Connection")
                    .font(.title3.weight(.semibold))
                Text("Profile metadata only. Credential values are not stored in this profile.")
                    .font(SSHStudioTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(SSHStudioSpacing.lg)
    }

    private var generalSection: some View {
        Section {
            TextField("Display Name", text: $name)
                .textContentType(.name)
            TextField("Host", text: $host)
                .textContentType(.URL)
            LabeledContent("Port") {
                TextField("Port", value: $port, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
            }
            TextField("Username", text: $username)
                .textContentType(.username)
            Toggle("Favorite", isOn: $favorite)
            TextField("Group", text: $group)
        } header: {
            Text("General")
        } footer: {
            Text("Use Host for direct connections, or set an SSH config alias in Advanced when OpenSSH should resolve the target.")
        }
    }

    private var authenticationSection: some View {
        Section {
            Picker("Method", selection: $authMethod) {
                ForEach(Session.AuthMethod.allCases, id: \.self) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            if authMethod == .privateKey {
                HStack {
                    TextField("Private Key", text: $privateKeyPath)
                    Button("Choose...") { choosePrivateKey() }
                }
                Text("Private-key paths are sensitive operational metadata. SSH Studio does not store private-key contents.")
                    .font(SSHStudioTypography.metadata)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Credential Reference") {
                Text(credentialReferenceID.isEmpty ? "None" : "Stored reference")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("Passwords and passphrases are not placed in saved profiles or injected into OpenSSH.")
        }
    }

    private var securitySection: some View {
        Section {
            LabeledContent("Host-Key Policy") {
                Label("OpenSSH and SSH Studio verification", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Known Hosts") {
                Text("Verified before connection")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Unknown host keys require explicit trust. Changed keys block connection until managed deliberately.")
        }
    }

    private var networkSection: some View {
        Section {
            TextField("SSH Config Alias", text: $sshConfigAlias)
            LabeledContent("Keepalive") {
                Text("Managed by current OpenSSH options")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Compression") {
                Text("Not configured in this profile")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Network")
        } footer: {
            Text("SSH config aliases are resolved by OpenSSH and may reveal routing information.")
        }
    }

    private var terminalSection: some View {
        Section {
            TextField("Remote Start Directory", text: $remoteStartDirectory)
            LabeledContent("Terminal Font") {
                Text("Configured in Terminal Settings")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Terminal and Files")
        } footer: {
            Text("Remote paths can be sensitive. They are redacted in diagnostics where possible.")
        }
    }

    private var tunnelsSection: some View {
        Section {
            if tunnels.isEmpty {
                Text("No saved forwarding rules")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tunnels) { tunnel in
                    LabeledContent(tunnel.name.isEmpty ? tunnel.type.rawValue : tunnel.name) {
                        Text("\(tunnel.listenHost):\(tunnel.localPort)")
                            .font(SSHStudioTypography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Tunnels")
        } footer: {
            Text("Forwarding rules are edited from the Tunnels workspace.")
        }
    }

    private var remoteScreenSection: some View {
        Section {
            Picker("Mode", selection: $remoteScreenMode) {
                ForEach(Session.RemoteScreenMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            TextField("Screen Host", text: $screenSharingHost)
            LabeledContent("Screen Port") {
                TextField("Port", value: $screenSharingPort, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
            }
            TextField("Remote Access Address", text: $remoteAccessAddress)
        } header: {
            Text("Remote Screen")
        }
    }

    private var advancedSection: some View {
        Section {
            LabeledContent("Profile ID") {
                Text((existing?.id ?? UUID()).uuidString)
                    .font(SSHStudioTypography.metadata)
                    .textSelection(.enabled)
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Validation error: \(validationMessage)")
            } else {
                Label("Profile is valid", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Advanced")
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Create" : "Save") {
                onSave(makeSession())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(validationMessage != nil)
        }
        .padding(SSHStudioSpacing.lg)
        .background(SSHStudioColors.paneBackground)
    }

    private var validationMessage: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Display name is required." }
        do {
            try SSHSecurity.validate(session: makeSession())
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func makeSession() -> Session {
        Session(
            id: existing?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            authMethod: authMethod,
            privateKeyPath: privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines),
            sshConfigAlias: sshConfigAlias.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialReferenceID: credentialReferenceID,
            remoteStartDirectory: remoteStartDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            remoteDirectory: remoteStartDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
            screenSharingHost: screenSharingHost.trimmingCharacters(in: .whitespacesAndNewlines),
            screenSharingPort: screenSharingPort,
            remoteScreenMode: remoteScreenMode,
            remoteAccessAddress: remoteAccessAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            tunnels: tunnels,
            favorite: favorite,
            group: group.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose Private Key"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }
}
