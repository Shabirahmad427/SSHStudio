import SwiftUI

struct HostKeyTrustSheet: View {
    let state: SSHHostTrustState
    var onTrust: (SSHHostKeyCandidate) -> Void
    var onCancel: () -> Void
    var onOpenManager: () -> Void

    var body: some View {
        Group {
            switch state {
            case .unknown(let candidates):
                if let candidate = candidates.first {
                    UnknownHostKeyView(candidate: candidate, onTrust: onTrust, onCancel: onCancel)
                } else {
                    HostKeyUnavailableView(message: "No host-key candidates were found.", onCancel: onCancel)
                }
            case .changed(let previous, let presented):
                ChangedHostKeyView(
                    previous: previous,
                    presented: presented,
                    onCancel: onCancel,
                    onOpenManager: onOpenManager
                )
            case .failed(let message), .unavailable(let message):
                HostKeyUnavailableView(message: message, onCancel: onCancel)
            default:
                HostKeyUnavailableView(message: "No host-key action is required.", onCancel: onCancel)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 680)
        .padding(22)
    }
}

private struct UnknownHostKeyView: View {
    let candidate: SSHHostKeyCandidate
    var onTrust: (SSHHostKeyCandidate) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Verify Host Identity", systemImage: "key.viewfinder")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("This fingerprint is unverified until you compare it with a trusted source. Accepting it creates a trust-on-first-use pin.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HostKeyFactGrid(candidate: candidate)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Trust and Connect") { onTrust(candidate) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ChangedHostKeyView: View {
    let previous: SSHHostKeyRecord
    let presented: SSHHostKeyCandidate
    var onCancel: () -> Void
    var onOpenManager: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Host Identity Changed", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
                .accessibilityAddTraits(.isHeader)

            Text("The presented host key does not match the previously trusted identity. This can happen after a server reinstall, but it can also indicate interception. SSH Studio will not connect until you deliberately manage this trust record.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                CopyableFingerprintRow(label: "Previously trusted", value: previous.fingerprint.sha256)
                CopyableFingerprintRow(label: "Presented now", value: presented.fingerprint.sha256)
                Text("Host: \(presented.endpoint.displayName)")
                Text("Port: \(presented.endpoint.port)")
                Text("Previous source: \(previous.source.rawValue)")
                Text("Algorithms: \(previous.algorithm.rawValue) -> \(presented.algorithm.rawValue)")
            }
            .textSelection(.enabled)

            HStack {
                Button("Cancel Connection", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open Known Hosts Manager") { onOpenManager() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct HostKeyFactGrid: View {
    let candidate: SSHHostKeyCandidate

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow { Text("Display name").foregroundStyle(.secondary); Text(candidate.endpoint.displayName) }
            GridRow { Text("Hostname").foregroundStyle(.secondary); Text(candidate.endpoint.hostname) }
            GridRow { Text("Port").foregroundStyle(.secondary); Text("\(candidate.endpoint.port)") }
            GridRow { Text("Algorithm").foregroundStyle(.secondary); Text(candidate.algorithm.rawValue) }
            GridRow {
                Text("Fingerprint").foregroundStyle(.secondary)
                CopyableFingerprintRow(label: "", value: candidate.fingerprint.sha256)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }
}

private struct CopyableFingerprintRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            if !label.isEmpty {
                Text(label).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy fingerprint")
            .accessibilityLabel("Copy fingerprint")
        }
    }
}

private struct HostKeyUnavailableView: View {
    let message: String
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Host Identity Unavailable", systemImage: "key.slash")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
