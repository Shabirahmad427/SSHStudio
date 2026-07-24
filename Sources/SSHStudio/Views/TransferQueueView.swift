import SwiftUI

struct TransferConsoleView: View {
    var body: some View {
        VStack(spacing: 0) {
            TransferQueueView()
            Divider()
            ConnectionLogView()
        }
    }
}

struct TransferQueueView: View {
    @ObservedObject var queue = TransferQueue.shared

    var active:    [TransferItem] { queue.items.filter { if case .inProgress = $0.status { return true }; return false } }
    var queued:    [TransferItem] { queue.items.filter { if case .queued     = $0.status { return true }; return false } }
    var finished:  [TransferItem] { queue.items.filter {
        if case .completed = $0.status { return true }
        if case .failed    = $0.status { return true }
        if case .cancelled  = $0.status { return true }
        if case .skipped    = $0.status { return true }
        return false
    }}

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfers")
                        .font(.headline)
                    if queue.activeCount > 0 {
                        Text("\(queue.activeCount) active · \(queue.pendingCount) queued")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !queue.items.isEmpty {
                    Button {
                        copyToPasteboard(transferLogText)
                    } label: {
                        Label("Copy Log", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .help("Copy transfer log")
                }
                if !finished.isEmpty {
                    Button("Clear Done") { queue.clear() }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if queue.items.isEmpty {
                ContentUnavailableView(
                    "No Transfers",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("Upload or download files from the SFTP browser")
                )
            } else {
                List {
                    if !active.isEmpty {
                        Section("Active") {
                            ForEach(active) { TransferRowView(item: $0) }
                        }
                    }
                    if !queued.isEmpty {
                        Section("Queued") {
                            ForEach(queued) { TransferRowView(item: $0) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Completed") {
                            ForEach(finished) { TransferRowView(item: $0) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var transferLogText: String {
        Self.truncate(
            queue.items.prefix(50).map { TransferRowView.copyText(for: $0) }.joined(separator: "\n\n"),
            limit: 20_000
        )
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return "\(value.prefix(limit))\n... [transfer log truncated]"
    }
}

// MARK: - Transfer Row

struct TransferRowView: View {
    @ObservedObject var item: TransferItem

    var isActive: Bool { if case .inProgress = item.status { return true }; return false }
    var isFailed: Bool { if case .failed = item.status { return true }; return false }

    var accentColor: Color {
        if isFailed { return .red }
        if case .completed = item.status { return .green }
        switch item.direction {
        case .upload: return .orange
        case .download: return .blue
        case .serverToServer: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: icon + name + status badge
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: directionIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(item.statusLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? accentColor : .secondary)
                    if isActive && !item.profileLabel.isEmpty {
                        Text(item.profileLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if isFailed {
                    Button {
                        copyToPasteboard(Self.copyErrorText(for: item))
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy exact error")
                }

                if case .inProgress = item.status {
                    Button {
                        TransferQueue.shared.cancel(item)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("Cancel transfer")
                }

                if case .queued = item.status {
                    Button {
                        TransferQueue.shared.skip(item)
                    } label: {
                        Image(systemName: "forward.end.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Skip queued transfer")
                }

                // Percent badge while active
                if isActive && item.percentDone > 0 {
                    Text("\(Int(item.percentDone))%")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accentColor)
                        .frame(width: 36, alignment: .trailing)
                }
            }

            // Progress bar
            if isActive || (item.percentDone == 100) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                    .scaleEffect(y: 1.4)
            }

            // Row 2: transferred / total | speed | ETA
            if isActive {
                HStack(spacing: 0) {
                    // Bytes transferred
                    if item.bytesTransferred > 0 {
                        Label(item.transferredLabel, systemImage: "externaldrive")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .labelStyle(CompactLabelStyle())
                    }

                    Spacer()

                    // Speed
                    if !item.speedLabel.isEmpty {
                        Label(item.speedLabel, systemImage: "speedometer")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .labelStyle(CompactLabelStyle())
                    }

                    // ETA
                    if !item.eta.isEmpty && item.eta != "0:00:00" {
                        Text("·")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                        Label(item.eta, systemImage: "clock")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .labelStyle(CompactLabelStyle())
                    }
                }
            }

            // Completed: show total size
            if case .completed = item.status, item.totalBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) + " transferred")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !item.detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(item.detailLines.prefix(isActive ? 16 : 6).enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 5) {
                            Image(systemName: "doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12)
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, 2)
            }

            // Failed: show error
            if let failureLabel = item.failureLabel {
                Text(failureLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
        .contextMenu {
            Button("Copy Name") { copyToPasteboard(item.name) }
            Button("Copy Status") { copyToPasteboard(item.statusLabel) }
            if isFailed {
                Button("Copy Error") { copyToPasteboard(Self.copyErrorText(for: item)) }
            }
            Button("Copy Details") { copyToPasteboard(Self.copyText(for: item)) }
            if case .inProgress = item.status {
                Button("Cancel Transfer") { TransferQueue.shared.cancel(item) }
            }
            if case .queued = item.status {
                Button("Skip Transfer") { TransferQueue.shared.skip(item) }
            }
        }
    }

    static func copyText(for item: TransferItem) -> String {
        var parts = [
            directionTitle(for: item.direction),
            item.name,
            item.statusLabel
        ]
        if item.bytesTransferred > 0 || item.totalBytes > 0 {
            parts.append(item.transferredLabel)
        }
        if !item.speedLabel.isEmpty {
            parts.append(item.speedLabel)
        }
        if !item.eta.isEmpty {
            parts.append("ETA \(item.eta)")
        }
        if !item.detailLines.isEmpty {
            parts.append(item.detailLines.joined(separator: " | "))
        }
        return parts.joined(separator: " · ")
    }

    static func copyErrorText(for item: TransferItem) -> String {
        var lines = [
            "Transfer: \(item.name)",
            "Direction: \(directionTitle(for: item.direction))",
            "Status: \(item.statusLabel)"
        ]
        if !item.detailLines.isEmpty {
            lines.append("Details:")
            lines += item.detailLines
        }
        return lines.joined(separator: "\n")
    }

    private var directionIcon: String {
        switch item.status {
        case .completed:          return "checkmark"
        case .failed:             return "xmark"
        case .cancelled:          return "slash.circle"
        case .skipped:            return "forward.end.circle"
        case .preparing, .inProgress, .queued:
            switch item.direction {
            case .upload: return "arrow.up"
            case .download: return "arrow.down"
            case .serverToServer: return "arrow.left.arrow.right"
            }
        }
    }

    private var directionTitle: String {
        Self.directionTitle(for: item.direction)
    }

    private static func directionTitle(for direction: TransferDirection) -> String {
        switch direction {
        case .upload: return "Upload"
        case .download: return "Download"
        case .serverToServer: return "Server-to-server"
        }
    }
}

// Compact label: icon + text inline, no spacing overhead
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
