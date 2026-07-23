import SwiftUI

@MainActor
final class KnownHostsViewModel: ObservableObject {
    @Published var records: [SSHHostKeyRecord] = []
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var pendingRemoval: SSHHostKeyRecord?

    private let store: HostKeyStore

    init(store: HostKeyStore = ManagedHostKeyStore()) {
        self.store = store
    }

    var filteredRecords: [SSHHostKeyRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.endpoint.displayName.lowercased().contains(query) ||
            $0.fingerprint.sha256.lowercased().contains(query) ||
            $0.algorithm.rawValue.lowercased().contains(query)
        }
    }

    func refresh() {
        Task {
            do {
                records = try await store.listRecords().sorted {
                    $0.endpoint.displayName.localizedCaseInsensitiveCompare($1.endpoint.displayName) == .orderedAscending
                }
                errorMessage = nil
            } catch {
                errorMessage = DiagnosticRedactor.redact(error.localizedDescription)
            }
        }
    }

    func remove(_ record: SSHHostKeyRecord) {
        Task {
            do {
                try await store.removeManagedKey(id: record.id)
                pendingRemoval = nil
                refresh()
            } catch {
                errorMessage = DiagnosticRedactor.redact(error.localizedDescription)
            }
        }
    }
}

struct KnownHostsView: View {
    @StateObject private var model = KnownHostsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Known Hosts", systemImage: "key.horizontal")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
            }
            .padding()

            TextField("Search hosts or fingerprints", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }

            List(model.filteredRecords) { record in
                KnownHostRow(record: record, onRemove: { model.pendingRemoval = record })
            }
            .listStyle(.inset)

            HStack {
                Button("Reveal System known_hosts") {
                    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/known_hosts")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Spacer()
                Text("\(model.filteredRecords.count) managed entr\(model.filteredRecords.count == 1 ? "y" : "ies")")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .padding()
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.refresh() }
        .confirmationDialog(
            "Remove SSH Studio trust entry?",
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { if !$0 { model.pendingRemoval = nil } }
            ),
            presenting: model.pendingRemoval
        ) { record in
            Button("Remove Trust Entry", role: .destructive) { model.remove(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Only the SSH Studio-managed entry for \(record.endpoint.displayName) will be removed. System known-host files will not be changed.")
        }
    }
}

private struct KnownHostRow: View {
    let record: SSHHostKeyRecord
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.endpoint.displayName)
                    .font(.headline)
                Text(":\(record.endpoint.port)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(record.source == .sshStudio ? "SSH Studio" : "System")
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            HStack {
                Text(record.algorithm.rawValue)
                    .foregroundStyle(.secondary)
                Text(record.fingerprint.sha256)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.fingerprint.sha256, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy fingerprint")
            }

            HStack {
                if let date = record.dateAdded {
                    Text("Added \(date.formatted(date: .abbreviated, time: .shortened))")
                }
                if !record.profileIDs.isEmpty {
                    Text("\(record.profileIDs.count) profile association\(record.profileIDs.count == 1 ? "" : "s")")
                }
                Spacer()
                if record.source == .sshStudio {
                    Button("Remove", role: .destructive) { onRemove() }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
