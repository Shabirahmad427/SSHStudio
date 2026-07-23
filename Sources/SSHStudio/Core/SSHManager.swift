import Foundation

@MainActor
class SSHManager: ObservableObject {
    // Tracks active tunnel processes keyed by tunnel config ID
    @Published private(set) var activeTunnels: [UUID: Process] = [:]
    @Published private(set) var tunnelErrors: [UUID: String] = [:]
    @Published private(set) var tunnelStates: [UUID: SSHConnectionState] = [:]
    private var requestedTunnels: [UUID: (TunnelConfig, Session)] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectAttempts: [UUID: Int] = [:]
    private let reconnectPolicy = SSHReconnectPolicy()

    init() {
        _ = NotificationCenter.default.addObserver(
            forName: .sshStudioHostTrustApproved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let endpointKey = note.userInfo?["endpointKey"] as? String else { return }
            Task { @MainActor [weak self] in
                self?.resumeApprovedTunnels(endpointKey: endpointKey)
            }
        }
    }

    func sshArgs(for session: Session) -> [String] {
        (try? SSHCommandBuilder.terminalInvocation(for: session).arguments) ?? SSHSecurity.destinationArgs(for: session)
    }

    func startTunnel(tunnel: TunnelConfig, session: Session) {
        requestedTunnels[tunnel.id] = (tunnel, session)
        reconnectTasks[tunnel.id]?.cancel()
        reconnectTasks[tunnel.id] = nil
        verifyThenLaunchTunnel(tunnel: tunnel, session: session)
    }

    func stopTunnel(id: UUID) {
        requestedTunnels.removeValue(forKey: id)
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        reconnectAttempts.removeValue(forKey: id)
        activeTunnels[id]?.terminate()
        activeTunnels.removeValue(forKey: id)
        tunnelErrors.removeValue(forKey: id)
        tunnelStates[id] = .disconnected(Date(), exitStatus: nil)
    }

    func isTunnelActive(_ id: UUID) -> Bool {
        activeTunnels[id]?.isRunning ?? false
    }

    func isTunnelEnabled(_ id: UUID) -> Bool {
        requestedTunnels[id] != nil
    }

    func tunnelError(_ id: UUID) -> String? {
        tunnelErrors[id]
    }

    func isTunnelReconnecting(_ id: UUID) -> Bool {
        reconnectTasks[id] != nil
    }

    private func launchTunnel(tunnel: TunnelConfig, session: Session) {
        guard activeTunnels[tunnel.id] == nil else { return }
        tunnelStates[tunnel.id] = .preparing(Date())
        let invocation: SSHInvocation
        do {
            invocation = try SSHCommandBuilder.tunnelInvocation(for: tunnel, session: session)
        } catch {
            tunnelErrors[tunnel.id] = error.localizedDescription
            tunnelStates[tunnel.id] = .failed(Date(), message: DiagnosticRedactor.redact(error.localizedDescription))
            return
        }

        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        let errorPipe = Pipe()
        let errorReader = PipeReader(pipe: errorPipe)
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { @Sendable [weak self, weak process] terminated in
            let data = errorReader.collectedData()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                guard let self, let process else { return }
                self.handleTunnelExit(
                    id: tunnel.id,
                    process: process,
                    status: terminated.terminationStatus,
                    message: message
                )
            }
        }

        do {
            try process.run()
            errorReader.start()
            activeTunnels[tunnel.id] = process
            reconnectAttempts[tunnel.id] = 0
            tunnelErrors.removeValue(forKey: tunnel.id)
            tunnelStates[tunnel.id] = .connected(Date())
            ConnectionLog.shared.log("Tunnel started: \(tunnel.nameOrFallback)", level: .success, session: session.name)
        } catch {
            let message = error.localizedDescription
            tunnelErrors[tunnel.id] = message
            tunnelStates[tunnel.id] = .failed(Date(), message: DiagnosticRedactor.redact(message))
            ConnectionLog.shared.log("Tunnel failed: \(message)", level: .error, session: session.name)
            scheduleReconnectIfNeeded(id: tunnel.id)
        }
    }

    private func verifyThenLaunchTunnel(tunnel: TunnelConfig, session: Session) {
        let endpoint = SSHHostEndpoint(session: session)
        tunnelStates[tunnel.id] = .checkingHostIdentity(endpoint)
        Task { @MainActor [weak self] in
            guard let self, self.requestedTunnels[tunnel.id] != nil else { return }
            let state = await HostKeyVerificationModel.shared.evaluate(session: session)
            guard self.requestedTunnels[tunnel.id] != nil else { return }
            switch state {
            case .trustedBySystem, .trustedBySSHStudio:
                self.launchTunnel(tunnel: tunnel, session: session)
            case .unknown:
                self.tunnelStates[tunnel.id] = .awaitingHostVerification(endpoint)
            case .changed:
                let message = "Host identity changed. Tunnel blocked."
                self.tunnelErrors[tunnel.id] = message
                self.tunnelStates[tunnel.id] = .failed(Date(), message: message)
            case .failed(let message), .unavailable(let message):
                self.tunnelErrors[tunnel.id] = message
                self.tunnelStates[tunnel.id] = .failed(Date(), message: message)
            default:
                break
            }
        }
    }

    private func resumeApprovedTunnels(endpointKey: String) {
        for (id, pair) in requestedTunnels where SSHHostEndpoint(session: pair.1).key == endpointKey {
            guard activeTunnels[id] == nil else { continue }
            launchTunnel(tunnel: pair.0, session: pair.1)
        }
    }

    private func handleTunnelExit(id: UUID, process: Process, status: Int32, message: String?) {
        guard activeTunnels[id] === process else { return }
        activeTunnels.removeValue(forKey: id)
        guard requestedTunnels[id] != nil else { return }
        let detail = message?.isEmpty == false ? message! : "ssh exited with status \(status)"
        tunnelErrors[id] = detail
        tunnelStates[id] = .failed(Date(), message: DiagnosticRedactor.redact(detail))
        if let session = requestedTunnels[id]?.1 {
            ConnectionLog.shared.log("Tunnel disconnected: \(detail)", level: .warning, session: session.name)
        }
        scheduleReconnectIfNeeded(id: id)
    }

    private func scheduleReconnectIfNeeded(id: UUID) {
        guard let (tunnel, session) = requestedTunnels[id], tunnel.autoReconnect else { return }
        reconnectTasks[id]?.cancel()
        let nextAttempt = (reconnectAttempts[id] ?? 0) + 1
        guard nextAttempt <= reconnectPolicy.maxAttempts else {
            tunnelStates[id] = .failed(Date(), message: "Reconnect attempts exhausted")
            return
        }
        reconnectAttempts[id] = nextAttempt
        let delay = reconnectPolicy.delay(forAttempt: nextAttempt)
        tunnelStates[id] = .reconnecting(attempt: nextAttempt, nextAttempt: Date().addingTimeInterval(delay))
        reconnectTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.requestedTunnels[id] != nil else { return }
            self.reconnectTasks[id] = nil
            self.verifyThenLaunchTunnel(tunnel: tunnel, session: session)
        }
    }
}

private extension TunnelConfig {
    var nameOrFallback: String { name.isEmpty ? "Tunnel" : name }
}
