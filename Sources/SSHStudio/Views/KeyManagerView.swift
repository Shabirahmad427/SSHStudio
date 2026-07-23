import SwiftUI

struct KeyManagerView: View {
    @ObservedObject var keyManager = KeyManager.shared
    @State private var showGenerator = false
    @State private var selectedKey: SSHKey?
    @State private var copiedKeyID: UUID?

    var body: some View {
        HSplitView {
            // Key list
            VStack(spacing: 0) {
                HStack {
                    Text("SSH Keys")
                        .font(.headline)
                    Spacer()
                    Button {
                        showGenerator = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                .padding(10)

                Divider()

                if keyManager.keys.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No keys yet")
                            .foregroundColor(.secondary)
                        Button("Generate Key") { showGenerator = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    List(selection: $selectedKey) {
                        ForEach(keyManager.keys) { key in
                            KeyRow(key: key)
                                .tag(key)
                                .contextMenu {
                                    Button("Copy Public Key") { copyPublicKey(key) }
                                    Button("Show in Finder") { showInFinder(key) }
                                    Divider()
                                    Button("Delete", role: .destructive) { keyManager.delete(key) }
                                }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 220, maxWidth: 280)

            // Key detail
            if let key = selectedKey {
                KeyDetailView(key: key, copiedKeyID: $copiedKeyID)
            } else {
                VStack {
                    Spacer()
                    Text("Select a key to view details")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showGenerator) {
            KeyGeneratorView()
        }
    }

    private func copyPublicKey(_ key: SSHKey) {
        if let content = keyManager.publicKeyContent(key) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(content, forType: .string)
            copiedKeyID = key.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedKeyID = nil }
        }
    }

    private func showInFinder(_ key: SSHKey) {
        NSWorkspace.shared.selectFile(key.privateKeyPath, inFileViewerRootedAtPath: "")
    }
}

struct KeyRow: View {
    let key: SSHKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "key.fill")
                    .foregroundColor(.yellow)
                Text(key.name).font(.headline)
            }
            Text(key.keyType.rawValue)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct KeyDetailView: View {
    let key: SSHKey
    @Binding var copiedKeyID: UUID?
    @ObservedObject var keyManager = KeyManager.shared
    @State private var publicKeyContent: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.yellow)
                    VStack(alignment: .leading) {
                        Text(key.name).font(.title2.bold())
                        Text(key.keyType.rawValue).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)

                // Info
                GroupBox("Key Information") {
                    VStack(spacing: 0) {
                        InfoRow(label: "Type", value: key.keyType.rawValue)
                        Divider()
                        InfoRow(label: "Comment", value: key.comment)
                        Divider()
                        InfoRow(label: "Private Key", value: key.privateKeyPath)
                        Divider()
                        InfoRow(label: "Public Key", value: key.publicKeyPath)
                        Divider()
                        InfoRow(label: "Created", value: key.createdAt.formatted())
                    }
                }

                // Public key
                GroupBox("Public Key") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(publicKeyContent.isEmpty ? "Unable to read public key" : publicKeyContent)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)

                        HStack {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(publicKeyContent, forType: .string)
                                copiedKeyID = key.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedKeyID = nil }
                            } label: {
                                Label(copiedKeyID == key.id ? "Copied!" : "Copy to Clipboard",
                                      systemImage: copiedKeyID == key.id ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(4)
                }
            }
            .padding()
        }
        .onAppear {
            publicKeyContent = keyManager.publicKeyContent(key) ?? ""
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}

// MARK: - Key Generator

struct KeyGeneratorView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var keyManager = KeyManager.shared

    @State private var name = ""
    @State private var keyType: SSHKey.KeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isGenerating = false
    @State private var errorMessage = ""
    @State private var generated = false

    var passphraseMatch: Bool { passphrase == confirmPassphrase }

    var body: some View {
        VStack(spacing: 0) {
            Text("Generate SSH Key")
                .font(.headline)
                .padding()

            Divider()

            Form {
                TextField("Key Name", text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("Key Type", selection: $keyType) {
                    ForEach(SSHKey.KeyType.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }

                TextField("Comment (e.g. user@host)", text: $comment)
                    .textFieldStyle(.roundedBorder)

                SecureField("Passphrase (optional)", text: $passphrase)
                    .textFieldStyle(.roundedBorder)

                SecureField("Confirm Passphrase", text: $confirmPassphrase)
                    .textFieldStyle(.roundedBorder)

                if !confirmPassphrase.isEmpty && !passphraseMatch {
                    Text("Passphrases do not match")
                        .foregroundColor(.red)
                        .font(.footnote)
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundColor(.red).font(.footnote)
                }

                if generated {
                    Label("Key generated successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if isGenerating {
                    ProgressView().controlSize(.small)
                }
                Button("Generate") { generate() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || isGenerating || !passphraseMatch)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private func generate() {
        isGenerating = true
        errorMessage = ""
        let finalComment = comment.isEmpty ? "\(name)@sshstudio" : comment
        keyManager.generateKey(name: name, type: keyType, comment: finalComment, passphrase: passphrase) { result in
            isGenerating = false
            switch result {
            case .success:
                generated = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
            case .failure(let err):
                errorMessage = err.localizedDescription
            }
        }
    }
}
