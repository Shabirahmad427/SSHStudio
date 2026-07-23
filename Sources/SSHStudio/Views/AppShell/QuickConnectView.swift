import SwiftUI

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    var onConnect: (Session) -> Void

    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var alias = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Quick Connect") {
                    TextField("Host or SSH config alias", text: $host)
                    TextField("Username", text: $username)
                    TextField("Port", text: $port)
                        .frame(width: 90)
                    TextField("Display name", text: $alias)
                }
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Button("Connect") {
                    let session = Session(
                        name: alias.isEmpty ? host : alias,
                        host: host,
                        port: Int(port) ?? 22,
                        username: username,
                        sshConfigAlias: alias.isEmpty ? "" : alias
                    )
                    onConnect(session)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(validationMessage != nil)
            }
            .padding()
        }
        .frame(width: 430, height: 300)
    }

    private var validationMessage: String? {
        do {
            try SSHSecurity.validate(session: Session(
                name: alias.isEmpty ? host : alias,
                host: host,
                port: Int(port) ?? 0,
                username: username,
                sshConfigAlias: alias
            ))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
