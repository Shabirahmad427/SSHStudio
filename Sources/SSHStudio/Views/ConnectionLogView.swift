import SwiftUI

struct ConnectionLogView: View {
    @ObservedObject var log = ConnectionLog.shared
    @State private var filterText = ""
    @State private var selectedLevel: LogLevel? = nil

    var filtered: [LogEntry] {
        log.entries.filter { entry in
            let matchText = filterText.isEmpty || entry.message.localizedCaseInsensitiveContains(filterText) || entry.session.localizedCaseInsensitiveContains(filterText)
            let matchLevel = selectedLevel == nil || entry.level == selectedLevel
            return matchText && matchLevel
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Filter logs...", text: $filterText)
                    .textFieldStyle(.plain)

                Divider().frame(height: 16)

                ForEach([LogLevel.info, .success, .warning, .error], id: \.rawValue) { level in
                    Button {
                        selectedLevel = selectedLevel == level ? nil : level
                    } label: {
                        Text(level.rawValue)
                            .font(.footnote)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(selectedLevel == level ? levelColor(level).opacity(0.2) : Color.clear)
                            .foregroundColor(levelColor(level))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
                Button("Clear") { log.clear() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if filtered.isEmpty {
                Spacer()
                Text("No log entries").foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTime)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .leading)

                                Text(entry.level.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(levelColor(entry.level))
                                    .frame(width: 44, alignment: .center)
                                    .padding(.horizontal, 4)
                                    .background(levelColor(entry.level).opacity(0.1))
                                    .cornerRadius(3)

                                Text(entry.session)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.blue)
                                    .frame(width: 80, alignment: .leading)
                                    .lineLimit(1)

                                Text(entry.message)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                            .textSelection(.enabled)
                            .contextMenu {
                                Button("Copy Message") { copyToPasteboard(entry.message) }
                                Button("Copy Row") { copyToPasteboard(rowText(for: entry)) }
                                Button("Copy Session") { copyToPasteboard(entry.session) }
                            }

                            Divider()
                        }
                    }
                }
            }
        }
    }

    func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .info:    return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }

    func rowText(for entry: LogEntry) -> String {
        "\(entry.formattedTime) \(entry.level.rawValue) \(entry.session) \(entry.message)"
    }
}

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
