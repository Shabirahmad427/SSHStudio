import SwiftUI
import SwiftTerm

struct TerminalTabView: View {
    let session: Session
    @ObservedObject private var termSettings = TerminalSettings.shared
    @EnvironmentObject private var connectionService: SSHConnectionService
    @EnvironmentObject private var hostKeyModel: HostKeyVerificationModel
    @State private var connectionNotice: String?

    var body: some View {
        ZStack {
            terminalStack
            if let connectionNotice {
                VStack {
                    HStack {
                        Label(connectionNotice, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                    Spacer()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sshTerminalDidTerminate)) { note in
            guard let payload = note.userInfo,
                  let name = payload["sessionName"] as? String,
                  name == session.name
            else { return }

            let exitCode = payload["exitCode"] as? Int32
            let tail = payload["tail"] as? String ?? ""
            let exitLabel = exitCode.map { "SSH exited with code \($0)" } ?? "SSH disconnected"
            let details = tail.isEmpty ? exitLabel : "\(exitLabel): \(tail)"
            connectionNotice = details
            connectionService.processTerminated(exitStatus: exitCode, message: tail)
            ConnectionLog.shared.log(details, level: .error, session: session.name)
        }
    }

    // Extracted so the full-screen overlay can reuse the same terminal stack
    private var terminalStack: some View {
        VStack(spacing: 0) {
            SSHTerminalView(
                invocation: terminalInvocation(for: session),
                sessionName: session.name,
                settings: termSettings,
                verifyHost: {
                    await verifyHostBeforeConnect()
                },
                onPrepare: {
                    connectionService.prepare()
                },
                onConnect: {
                    connectionNotice = nil
                    connectionService.processStarted()
                    ConnectionLog.shared.log("SSH process started", level: .info, session: session.name)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(termSettings.resolvedBackground))
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func sshArgs(for session: Session) -> [String] {
        terminalInvocation(for: session).arguments
    }

    private func terminalInvocation(for session: Session) -> SSHInvocation {
        do {
            return try SSHCommandBuilder.terminalInvocation(for: session)
        } catch {
            let message = DiagnosticRedactor.redact(error.localizedDescription)
            connectionService.processTerminated(exitStatus: 255, message: message)
            return SSHInvocation(
                purpose: .terminal,
                executableURL: SSHCommandBuilder.sshExecutableURL,
                arguments: ["-V"],
                hostKeyPolicy: .openSSHDefault,
                sensitiveValues: []
            )
        }
    }

    @MainActor
    private func verifyHostBeforeConnect() async -> Bool {
        let endpoint = SSHHostEndpoint(session: session)
        connectionService.checkingHostIdentity(endpoint)
        let state = await hostKeyModel.evaluate(session: session)
        switch state {
        case .trustedBySystem, .trustedBySSHStudio:
            return true
        case .unknown:
            connectionService.awaitingHostVerification(endpoint)
            return false
        case .changed:
            connectionService.hostIdentityFailed("Host identity changed. Connection blocked.")
            return false
        case .failed(let message), .unavailable(let message):
            connectionService.hostIdentityFailed(message)
            return false
        default:
            return false
        }
    }
}

// MARK: - NSViewRepresentable Terminal

struct SSHTerminalView: NSViewRepresentable {
    let invocation: SSHInvocation
    let sessionName: String
    @ObservedObject var settings: TerminalSettings
    var verifyHost: (@MainActor @Sendable () async -> Bool)? = nil
    var onPrepare: (@MainActor @Sendable () -> Void)? = nil
    var onConnect: (@MainActor @Sendable () -> Void)? = nil

    // Tracks last-applied values so updateNSView is a no-op when nothing changed
    class Coordinator {
        var appliedFontSize: CGFloat = 0
        var appliedFontName: String = ""
        var appliedThemeID: String = ""
        var appliedUseCustom: Bool = false
        var appliedBG: NSColor = .black
        var appliedFG: NSColor = .white
        var appliedCursor: NSColor = .white
        var appliedSelection: NSColor = .blue
        var sessionName: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let tv = StudioTerminalView(frame: .zero)
        applySettings(tv, coordinator: context.coordinator, force: true)
        tv.processDelegate = context.coordinator
        context.coordinator.sessionName = sessionName
        if let onPrepare {
            Task { @MainActor in
                onPrepare()
            }
        }
        Task { @MainActor in
            if let verifyHost {
                guard await verifyHost() else { return }
            }
            tv.startProcess(executable: invocation.executableURL.path, args: invocation.arguments)
            if let onConnect {
                onConnect()
            }
        }
        return tv
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        applySettings(nsView, coordinator: context.coordinator, force: false)
        context.coordinator.sessionName = sessionName
    }

    private func applySettings(_ tv: LocalProcessTerminalView, coordinator: Coordinator, force: Bool) {
        let newFont     = settings.resolvedFont
        let newBG       = settings.resolvedBackground
        let newFG       = settings.resolvedForeground
        let newCursor   = settings.resolvedCursor
        let newSelect   = settings.resolvedSelection

        let fontChanged   = force || newFont.pointSize != coordinator.appliedFontSize
                                  || newFont.fontName  != coordinator.appliedFontName
        let colorChanged  = force
                         || coordinator.appliedThemeID    != settings.themeID
                         || coordinator.appliedUseCustom  != settings.useCustomColors
                         || !coordinator.appliedBG.isEqual(newBG)
                         || !coordinator.appliedFG.isEqual(newFG)
                         || !coordinator.appliedCursor.isEqual(newCursor)
                         || !coordinator.appliedSelection.isEqual(newSelect)

        if fontChanged {
            tv.font = newFont
            coordinator.appliedFontSize = newFont.pointSize
            coordinator.appliedFontName = newFont.fontName
        }

        if colorChanged {
            tv.nativeForegroundColor      = newFG
            tv.nativeBackgroundColor      = newBG
            tv.caretColor                 = newCursor
            tv.selectedTextBackgroundColor = newSelect
            coordinator.appliedThemeID    = settings.themeID
            coordinator.appliedUseCustom  = settings.useCustomColors
            coordinator.appliedBG         = newBG
            coordinator.appliedFG         = newFG
            coordinator.appliedCursor     = newCursor
            coordinator.appliedSelection  = newSelect
        }
    }
}

extension SSHTerminalView.Coordinator: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let terminatedSessionName = sessionName
        MainActor.assumeIsolated {
            guard let terminalView = source as? LocalProcessTerminalView else { return }
            let output = String(data: terminalView.terminal.getBufferAsData(), encoding: .utf8) ?? ""
            let lines = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let tail = lines.suffix(4).joined(separator: " | ")
            NotificationCenter.default.post(
                name: .sshTerminalDidTerminate,
                object: nil,
                userInfo: [
                    "sessionName": terminatedSessionName,
                    "exitCode": exitCode as Any,
                    "tail": tail
                ]
            )
        }
    }
}

extension Notification.Name {
    static let sshTerminalDidTerminate = Notification.Name("sshTerminalDidTerminate")
}

final class StudioTerminalView: LocalProcessTerminalView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = getSelection()?.isEmpty == false
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string)?.isEmpty == false
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAllTerminal(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        let openItem = NSMenuItem(title: "Open Selection", action: #selector(openSelection(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = selectionOpenTarget() != nil
        menu.addItem(openItem)

        return menu
    }

    @objc override func copy(_ sender: Any?) {
        guard let selection = getSelection(), !selection.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selection, forType: .string)
    }

    @objc override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        send(txt: text)
    }

    @objc private func selectAllTerminal(_ sender: Any?) {
        selectAll()
    }

    @objc private func openSelection(_ sender: Any?) {
        guard let target = selectionOpenTarget() else { return }
        NSWorkspace.shared.open(target)
    }

    private func selectionOpenTarget() -> URL? {
        guard let selection = getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.isEmpty
        else { return nil }

        if let url = URL(string: selection), ["http", "https", "file"].contains(url.scheme?.lowercased()) {
            return url
        }

        let expanded = (selection as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
    }
}
