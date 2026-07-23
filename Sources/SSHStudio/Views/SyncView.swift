import SwiftUI

struct SyncView: View {
    let session: Session
    let allSessions: [Session]

    @StateObject private var syncManager = SyncManager()
    @State private var localPath: URL = URL(fileURLWithPath: NSHomeDirectory())
    @State private var remotePath: String = "~"
    @State private var destinationPath: String = "~"
    @State private var direction: SyncDirection = .localToRemote
    @State private var destinationSessionID: Session.ID?

    private var destinationSessions: [Session] {
        allSessions.filter { $0.id != session.id }
    }

    private var selectedDestinationSession: Session? {
        let id = destinationSessionID ?? destinationSessions.first?.id
        return destinationSessions.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Directory Sync")
                    .font(.headline)
                Spacer()
                Text(session.name)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(12)

            Divider()

            VStack(spacing: 16) {
                Picker("Direction", selection: $direction) {
                    Label("Local -> Remote", systemImage: "arrow.right").tag(SyncDirection.localToRemote)
                    Label("Remote -> Local", systemImage: "arrow.left").tag(SyncDirection.remoteToLocal)
                    Label("Server -> Server", systemImage: "arrow.right.arrow.left").tag(SyncDirection.serverToServer)
                    Label("Mirror (sync + delete)", systemImage: "arrow.left.arrow.right").tag(SyncDirection.mirror)
                }
                .pickerStyle(.segmented)

                if direction == .serverToServer {
                    serverToServerControls
                } else {
                    localRemoteControls
                }

                if direction == .mirror {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Mirror mode will delete files on the destination that don't exist in the source.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                Button {
                    startSync()
                } label: {
                    HStack {
                        if syncManager.isSyncing {
                            ProgressView().controlSize(.small)
                            Text("Syncing...")
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Start Sync")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(syncManager.isSyncing || (direction == .serverToServer && selectedDestinationSession == nil))
            }
            .padding()
            .onAppear {
                if destinationSessionID == nil {
                    destinationSessionID = destinationSessions.first?.id
                }
            }
            .onChange(of: allSessions) { _, _ in
                if selectedDestinationSession == nil {
                    destinationSessionID = destinationSessions.first?.id
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Output")
                        .font(.footnote.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    if !syncManager.syncLog.isEmpty {
                        Button("Clear") { syncManager.syncLog.removeAll() }
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(syncManager.syncLog.indices, id: \.self) { i in
                            Text(syncManager.syncLog[i])
                                .font(.system(size: 13, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                        }
                    }
                }
                .frame(height: 150)
                .background(Color.black.opacity(0.05))
            }
        }
    }

    private var localRemoteControls: some View {
        Group {
            GroupBox("Local Directory") {
                HStack {
                    Image(systemName: "desktopcomputer")
                        .foregroundColor(.secondary)
                    Text(localPath.path)
                        .font(.system(size: 14, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            localPath = url
                        }
                    }
                    .controlSize(.small)
                }
                .padding(4)
            }

            GroupBox("Remote Directory") {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.secondary)
                    TextField("Remote path", text: $remotePath)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(4)
            }
        }
    }

    private var serverToServerControls: some View {
        Group {
            GroupBox("Source Server") {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.secondary)
                    Text(session.name)
                        .font(.system(size: 14, design: .monospaced))
                    Spacer()
                }
                .padding(4)
            }

            GroupBox("Source Remote Directory") {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    TextField("Source path", text: $remotePath)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(4)
            }

            GroupBox("Destination Server") {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.secondary)
                    Picker("Destination", selection: Binding(
                        get: { destinationSessionID ?? destinationSessions.first?.id },
                        set: { destinationSessionID = $0 }
                    )) {
                        ForEach(destinationSessions) { destination in
                            Text(destination.name).tag(Optional(destination.id))
                        }
                    }
                    .labelsHidden()
                }
                .padding(4)
            }

            GroupBox("Destination Remote Directory") {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    TextField("Destination path", text: $destinationPath)
                        .font(.system(size: 14, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                .padding(4)
            }
        }
    }

    private func startSync() {
        if direction == .serverToServer, let selectedDestinationSession {
            syncManager.syncServerToServer(
                sourceSession: session,
                sourcePath: remotePath,
                destinationSession: selectedDestinationSession,
                destinationPath: destinationPath
            ) {}
            return
        }

        syncManager.sync(
            localPath: localPath,
            remotePath: remotePath,
            direction: direction,
            session: session
        ) {}
    }
}
