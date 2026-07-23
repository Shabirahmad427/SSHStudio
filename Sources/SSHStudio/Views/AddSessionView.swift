import SwiftUI

struct AddSessionView: View {
    @Environment(\.dismiss) var dismiss
    var existing: Session? = nil
    var onSave: (Session) -> Void

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authMethod: Session.AuthMethod = .password
    @State private var privateKeyPath: String = ""
    @State private var sshConfigAlias: String = ""
    @State private var remoteDirectory: String = ""
    @State private var screenSharingHost: String = ""
    @State private var screenSharingPort: String = "5900"
    @State private var remoteScreenMode: Session.RemoteScreenMode = .sshTunnel
    @State private var remoteAccessAddress = ""
    @State private var selectedEditorTab: EditorTab = .ssh

    private enum EditorTab: String, CaseIterable {
        case ssh = "SSH Connection"
        case screen = "Remote Screen"

        var icon: String {
            switch self {
            case .ssh: return "terminal.fill"
            case .screen: return "display"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(
                            colors: [StudioTheme.accent, StudioTheme.accentBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "server.rack")
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "New Saved Session" : "Edit Saved Session")
                        .font(.system(size: 16, weight: .bold))
                    Text("Configure SSH access and optional remote desktop tools")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(EditorTab.allCases, id: \.self) { tab in
                        Button {
                            selectedEditorTab = tab
                        } label: {
                            Label(tab.rawValue, systemImage: tab.icon)
                                .font(.system(size: 13, weight: selectedEditorTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedEditorTab == tab ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 9)
                                .background {
                                    if selectedEditorTab == tab {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.accentColor.opacity(0.12))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 160)
                .background(.ultraThinMaterial)

                Divider()

                ScrollView {
                    Form {
                        switch selectedEditorTab {
                        case .ssh:
                            sshForm
                        case .screen:
                            remoteScreenForm
                        }
                    }
                    .formStyle(.grouped)
                    .padding(10)
                }
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || validationMessage != nil || screenValidationMessage != nil)
            }
            .padding()
        }
        .frame(width: 680, height: 530)
        .onAppear { prefill() }
    }

    @ViewBuilder
    private var sshForm: some View {
        Section("Connection") {
            TextField("Session name", text: $name, prompt: Text("My Linux Lab"))
            TextField("Hostname or IP address", text: $host)
            LabeledContent("SSH port") {
                TextField("22", text: $port)
                    .frame(width: 90)
            }
            TextField("Username", text: $username)
            if let validationMessage {
                validationText(validationMessage)
            }
        }

        Section("SSH Config Alias") {
            TextField("Optional ~/.ssh/config alias", text: $sshConfigAlias)
            Text("Use an alias when your SSH config defines ProxyJump or other host-specific options.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Directory Browser") {
            TextField("Remote start directory", text: $remoteDirectory, prompt: Text("~"))
            Text("The SFTP Directory tab opens here first. For docinho, use /media/shabir/Expansion or /media/shabir/Coaraci.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Section("Authentication") {
            Picker("Method", selection: $authMethod) {
                ForEach(Session.AuthMethod.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.segmented)

            if authMethod == .privateKey {
                HStack {
                    TextField("Private key path", text: $privateKeyPath)
                    Button("Browse") { selectPrivateKey() }
                }
            }
        }
    }

    @ViewBuilder
    private var remoteScreenForm: some View {
        Section("Remote Desktop Provider") {
            Picker("Connection mode", selection: $remoteScreenMode) {
                ForEach(Session.RemoteScreenMode.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.radioGroup)
        }

        Section(remoteScreenMode.rawValue) {
            if remoteScreenMode == .sshTunnel || remoteScreenMode == .directVNC {
                TextField(remoteScreenMode == .sshTunnel ? "Display host from lab machine (default: localhost)" : "VNC host or IP", text: $screenSharingHost)
                LabeledContent("VNC port") {
                    TextField("5900", text: $screenSharingPort)
                        .frame(width: 90)
                }
            } else if remoteScreenMode == .anyDesk {
                TextField("AnyDesk ID or Alias", text: $remoteAccessAddress)
            } else {
                TextField("DWService agent name (optional)", text: $remoteAccessAddress)
            }

            if let screenValidationMessage {
                validationText(screenValidationMessage)
            }
            Text(remoteScreenHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if remoteScreenMode == .dwService {
            Section("Linux Lab Setup") {
                Label("Use this mode when the DWService Agent is already installed on the Linux lab machine.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("After saving, open the Screen tab. DWService loads inside SSH Studio. Sign in once, select your registered Linux machine, and open its Screen application.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func validationText(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    private func selectPrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            privateKeyPath = panel.url?.path ?? ""
        }
    }

    private func prefill() {
        guard let s = existing else { return }
        name = s.name
        host = s.host
        port = "\(s.port)"
        username = s.username
        authMethod = s.authMethod
        privateKeyPath = s.privateKeyPath
        sshConfigAlias = s.sshConfigAlias
        remoteDirectory = s.remoteDirectory
        screenSharingHost = s.screenSharingHost
        screenSharingPort = "\(s.screenSharingPort)"
        remoteScreenMode = s.remoteScreenMode
        remoteAccessAddress = s.remoteAccessAddress
    }

    private func save() {
        var session = existing ?? Session(name: "", host: "", username: "")
        session.name = name
        session.host = host
        session.port = Int(port) ?? 22
        session.username = username
        session.authMethod = authMethod
        session.privateKeyPath = privateKeyPath
        session.sshConfigAlias = sshConfigAlias
        session.remoteDirectory = remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        session.screenSharingHost = screenSharingHost
        session.screenSharingPort = Int(screenSharingPort) ?? 5900
        session.remoteScreenMode = remoteScreenMode
        session.remoteAccessAddress = remoteAccessAddress
        onSave(session)
        dismiss()
    }

    private var validationMessage: String? {
        let session = Session(
            name: name,
            host: host,
            port: Int(port) ?? 0,
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            sshConfigAlias: sshConfigAlias
        )
        do {
            try SSHSecurity.validate(session: session)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var screenValidationMessage: String? {
        if remoteScreenMode == .anyDesk {
            return remoteAccessAddress.isEmpty ? "Enter the AnyDesk ID or Alias shown by the agent on the lab machine." : nil
        }
        if remoteScreenMode == .dwService {
            return nil
        }
        guard !screenSharingHost.isEmpty else { return nil }
        guard screenSharingHost.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\r\n/?#@")) == nil else {
            return "Screen Sharing host contains unsupported characters."
        }
        guard let port = Int(screenSharingPort), (1...65535).contains(port) else {
            return "VNC port must be between 1 and 65535."
        }
        return nil
    }

    private var remoteScreenHelp: String {
        switch remoteScreenMode {
        case .sshTunnel:
            return "Recommended when the lab machine runs Screen Sharing or VNC. SSH Studio forwards the display securely through SSH. Leave the display host empty when VNC runs on the lab machine itself."
        case .directVNC:
            return "Connects directly with the macOS Screen Sharing app. The remote VNC service must be reachable from this Mac."
        case .anyDesk:
            return "Launches an installed AnyDesk client using the lab machine's AnyDesk ID or Alias. Install and configure AnyDesk on both machines first."
        case .dwService:
            return "Loads the DWService dashboard inside SSH Studio. Install and register the DWService Agent on the lab machine first, then select its Screen application in the embedded panel."
        }
    }
}
