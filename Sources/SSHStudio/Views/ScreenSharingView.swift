import AppKit
import Network
import SwiftUI
import WebKit

struct ScreenSharingView: View {
    let session: Session
    @State private var errorMessage: String?
    @State private var isChecking = false
    @ObservedObject private var tunnelManager = ScreenSharingTunnelManager.shared

    private var screenHost: String {
        if !session.screenSharingHost.isEmpty { return session.screenSharingHost }
        return session.remoteScreenMode == .sshTunnel ? "127.0.0.1" : session.host
    }

    var body: some View {
        if session.remoteScreenMode == .dwService {
            DWServicePanel(agentName: session.remoteAccessAddress)
        } else {
            screenLauncher
        }
    }

    private var screenLauncher: some View {
        ZStack {
            StudioBackdrop()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(width: 104, height: 104)
                    Image(systemName: "display")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.cyan)
                }

                VStack(spacing: 6) {
                    Text("Remote Screen")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(screenSubtitle)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    ScreenFeatureBadge(icon: "lock.shield.fill", title: "macOS client")
                    if session.remoteScreenMode == .sshTunnel {
                        ScreenFeatureBadge(icon: "lock.fill", title: "SSH tunnel")
                    } else if session.remoteScreenMode == .anyDesk {
                        ScreenFeatureBadge(icon: "person.badge.key.fill", title: "AnyDesk agent")
                    } else if session.remoteScreenMode == .dwService {
                        ScreenFeatureBadge(icon: "globe", title: "DWService agent")
                    }
                    if session.remoteScreenMode == .sshTunnel || session.remoteScreenMode == .directVNC {
                        ScreenFeatureBadge(icon: "network", title: "VNC :\(session.screenSharingPort)")
                    }
                }

                Button {
                    Task { await openScreenSharing() }
                } label: {
                    HStack(spacing: 8) {
                        if isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "display.and.arrow.down")
                        }
                        Text(isChecking ? "Checking Screen Service..." : connectButtonTitle)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isChecking)

                if session.remoteScreenMode == .sshTunnel, tunnelManager.isActive(session.id) {
                    Button("Stop Screen Tunnel") {
                        tunnelManager.stop(sessionID: session.id)
                    }
                    .buttonStyle(.borderless)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text(screenHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .padding(32)
        }
    }

    private func openScreenSharing() async {
        errorMessage = nil
        if session.remoteScreenMode == .anyDesk {
            openAnyDesk()
            return
        }
        guard (1...65535).contains(session.screenSharingPort),
              isValidScreenHost(screenHost) else {
            errorMessage = "Enter a valid Screen Sharing host and VNC port in the saved session."
            return
        }

        isChecking = true
        let endpoint: (host: String, port: Int)
        if session.remoteScreenMode == .sshTunnel {
            do {
                endpoint = try await tunnelManager.start(session: session, displayHost: screenHost)
            } catch {
                isChecking = false
                errorMessage = error.localizedDescription
                ConnectionLog.shared.log("Remote screen tunnel failed: \(error.localizedDescription)", level: .warning, session: session.name)
                return
            }
        } else {
            endpoint = (screenHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), session.screenSharingPort)
            let probeResult = await ScreenSharingProbe.check(host: endpoint.host, port: endpoint.port)
            guard probeResult == nil else {
                isChecking = false
                errorMessage = probeResult
                ConnectionLog.shared.log("Remote screen unavailable: \(probeResult!)", level: .warning, session: session.name)
                return
            }
        }
        isChecking = false

        var components = URLComponents()
        components.scheme = "vnc"
        components.host = endpoint.host
        components.port = endpoint.port
        guard let url = components.url else {
            errorMessage = "The Screen Sharing address could not be created."
            return
        }

        NSWorkspace.shared.open(url)
        ConnectionLog.shared.log("Opened remote screen: \(screenHost)", level: .info, session: session.name)
    }

    private func openAnyDesk() {
        let address = session.remoteAccessAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty,
              address.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\r\n/?#")) == nil,
              let url = URL(string: "anydesk:\(address)") else {
            errorMessage = "Enter the AnyDesk ID or Alias shown by the agent on the lab machine."
            return
        }
        NSWorkspace.shared.open(url)
        ConnectionLog.shared.log("Opened AnyDesk remote screen: \(address)", level: .info, session: session.name)
    }

    private var connectButtonTitle: String {
        switch session.remoteScreenMode {
        case .anyDesk: return "Open AnyDesk"
        case .dwService: return "Open DWService"
        case .sshTunnel, .directVNC: return "Connect Screen"
        }
    }

    private var screenSubtitle: String {
        switch session.remoteScreenMode {
        case .sshTunnel: return "Visualize the lab display securely through SSH"
        case .directVNC: return "Connect to \(screenHost) using macOS Screen Sharing"
        case .anyDesk: return "Connect with the AnyDesk agent installed on the lab machine"
        case .dwService: return "Connect with the DWService agent installed on the lab machine"
        }
    }

    private var screenHelp: String {
        switch session.remoteScreenMode {
        case .sshTunnel:
            return "The lab machine must run macOS Screen Sharing or a compatible VNC server. SSH Studio keeps the SSH tunnel open while you use Apple's Screen Sharing app."
        case .directVNC:
            return "SSH Studio checks the VNC service before launching Apple's Screen Sharing app. The remote VNC service must be reachable from this Mac."
        case .anyDesk:
            return "Install AnyDesk on this Mac and on the lab machine. Configure access on the lab machine, then save its AnyDesk ID or Alias in this session."
        case .dwService:
            return "Install and register the DWService Agent on the lab machine. The dashboard opens in your browser, where you can select the agent and launch its Screen application."
        }
    }

    private func isValidScreenHost(_ value: String) -> Bool {
        !value.isEmpty &&
            value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\r\n/?#@")) == nil
    }
}

private struct DWServicePanel: View {
    let agentName: String
    @StateObject private var browser = DWServiceBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("DWService", systemImage: "display")
                    .font(.system(size: 13, weight: .semibold))

                if !agentName.isEmpty {
                    Text(agentName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if browser.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    browser.goHome()
                } label: {
                    Image(systemName: "house")
                }
                .buttonStyle(.plain)
                .help("DWService dashboard")

                Button {
                    browser.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload")

                Button {
                    NSWorkspace.shared.open(browser.currentURL ?? DWServiceBrowserModel.homeURL)
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.plain)
                .help("Open in browser")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }

            DWServiceWebView(browser: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
private final class DWServiceBrowserModel: ObservableObject {
    static let homeURL = URL(string: "https://www.dwservice.net")!

    @Published private(set) var isLoading = false
    @Published private(set) var currentURL: URL?
    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: Self.homeURL))
    }

    func goHome() {
        webView.load(URLRequest(url: Self.homeURL))
    }

    func reload() {
        webView.reload()
    }

    func update(isLoading: Bool, url: URL?) {
        self.isLoading = isLoading
        currentURL = url
    }
}

private struct DWServiceWebView: NSViewRepresentable {
    @ObservedObject var browser: DWServiceBrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> WKWebView {
        browser.webView.navigationDelegate = context.coordinator
        return browser.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let browser: DWServiceBrowserModel

        init(browser: DWServiceBrowserModel) {
            self.browser = browser
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in browser.update(isLoading: true, url: webView.url) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in browser.update(isLoading: false, url: webView.url) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in browser.update(isLoading: false, url: webView.url) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in browser.update(isLoading: false, url: webView.url) }
        }
    }
}

@MainActor
private final class ScreenSharingTunnelManager: ObservableObject {
    static let shared = ScreenSharingTunnelManager()

    @Published private var processes: [UUID: Process] = [:]
    private var localPorts: [UUID: Int] = [:]

    func isActive(_ sessionID: UUID) -> Bool {
        processes[sessionID]?.isRunning == true
    }

    func start(session: Session, displayHost: String) async throws -> (host: String, port: Int) {
        if let process = processes[session.id],
           process.isRunning,
           let port = localPorts[session.id] {
            return ("127.0.0.1", port)
        }

        try SSHSecurity.validateNonInteractive(session: session, purpose: "Screen sharing over SSH")
        guard isValidForwardHost(displayHost) else {
            throw ScreenSharingTunnelError.invalidDisplayHost
        }

        stop(sessionID: session.id)
        let localPort = Int.random(in: 49152...65535)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=8",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(SSHSecurity.controlPath(for: session))",
            "-L", "127.0.0.1:\(localPort):\(displayHost):\(session.screenSharingPort)"
        ]
        args += SSHSecurity.baseOptions
        args += SSHSecurity.destinationArgs(for: session)
        process.arguments = args

        let errorPipe = Pipe()
        let errorReader = PipeReader(pipe: errorPipe)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.terminationHandler = { @Sendable [weak self] _ in
            errorReader.waitUntilFinished()
            Task { @MainActor in
                self?.processes.removeValue(forKey: session.id)
                self?.localPorts.removeValue(forKey: session.id)
            }
        }

        do {
            try process.run()
            errorReader.start()
        } catch {
            throw ScreenSharingTunnelError.launchFailed(error.localizedDescription)
        }

        processes[session.id] = process
        localPorts[session.id] = localPort

        let probeResult = await ScreenSharingProbe.check(host: "127.0.0.1", port: localPort)
        guard probeResult == nil else {
            stop(sessionID: session.id)
            throw ScreenSharingTunnelError.unavailable(
                "The lab display did not respond through SSH. Open the Terminal tab first if authentication is required, then confirm that Screen Sharing or a VNC server is running on \(displayHost):\(session.screenSharingPort)."
            )
        }

        ConnectionLog.shared.log("Opened screen tunnel to \(displayHost):\(session.screenSharingPort)", level: .success, session: session.name)
        return ("127.0.0.1", localPort)
    }

    func stop(sessionID: UUID) {
        processes[sessionID]?.terminate()
        processes.removeValue(forKey: sessionID)
        localPorts.removeValue(forKey: sessionID)
    }

    private func isValidForwardHost(_ value: String) -> Bool {
        !value.isEmpty &&
            value.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\r\n,/?#@")) == nil
    }
}

private enum ScreenSharingTunnelError: LocalizedError {
    case invalidDisplayHost
    case launchFailed(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidDisplayHost:
            return "Enter a valid display host reachable from the lab machine."
        case .launchFailed(let message):
            return "Could not start the SSH screen tunnel. \(message)"
        case .unavailable(let message):
            return message
        }
    }
}

private enum ScreenSharingProbe {
    static func check(host: String, port: Int) async -> String? {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return "The Screen Sharing port is invalid."
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
            let result = ScreenProbeResult(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    result.finish(nil)
                case .failed(let error):
                    result.finish("Screen Sharing is not reachable at \(host):\(port). \(error.localizedDescription)")
                case .cancelled:
                    result.finish("The Screen Sharing connection check was cancelled.")
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4) {
                result.finish("Screen Sharing did not respond at \(host):\(port). Confirm that VNC or macOS Screen Sharing is enabled and reachable from this Mac.")
            }
        }
    }
}

private final class ScreenProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<String?, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<String?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ message: String?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: message)
    }
}

private struct ScreenFeatureBadge: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}
