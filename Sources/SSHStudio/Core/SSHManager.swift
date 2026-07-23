import Foundation

@MainActor
class SSHManager: ObservableObject {
    // Tracks active tunnel processes keyed by tunnel config ID
    @Published private(set) var activeTunnels: [UUID: Process] = [:]
    @Published private(set) var tunnelErrors: [UUID: String] = [:]
    private var requestedTunnels: [UUID: (TunnelConfig, Session)] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    func sshArgs(for session: Session) -> [String] {
        SSHSecurity.destinationArgs(for: session)
    }

    func startTunnel(tunnel: TunnelConfig, session: Session) {
        requestedTunnels[tunnel.id] = (tunnel, session)
        reconnectTasks[tunnel.id]?.cancel()
        reconnectTasks[tunnel.id] = nil
        launchTunnel(tunnel: tunnel, session: session)
    }

    func stopTunnel(id: UUID) {
        requestedTunnels.removeValue(forKey: id)
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = nil
        activeTunnels[id]?.terminate()
        activeTunnels.removeValue(forKey: id)
        tunnelErrors.removeValue(forKey: id)
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
        do {
            try SSHSecurity.validateNonInteractive(session: session, purpose: "SSH tunnels")
            try SSHSecurity.validateTunnel(tunnel)
        } catch {
            tunnelErrors[tunnel.id] = error.localizedDescription
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args: [String] = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
        ]

        args += SSHSecurity.baseOptions
        args += sshArgs(for: session)

        switch tunnel.type {
        case .local:
            args.insert(contentsOf: ["-L", "\(tunnel.listenHost):\(tunnel.localPort):\(tunnel.remoteHost):\(tunnel.remotePort)"], at: 1)
        case .remote:
            args.insert(contentsOf: ["-R", "\(tunnel.listenHost):\(tunnel.remotePort):\(tunnel.remoteHost):\(tunnel.localPort)"], at: 1)
        case .dynamic:
            args.insert(contentsOf: ["-D", "\(tunnel.listenHost):\(tunnel.localPort)"], at: 1)
        }

        process.arguments = args
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
            tunnelErrors.removeValue(forKey: tunnel.id)
            ConnectionLog.shared.log("Tunnel started: \(tunnel.nameOrFallback)", level: .success, session: session.name)
        } catch {
            let message = error.localizedDescription
            tunnelErrors[tunnel.id] = message
            ConnectionLog.shared.log("Tunnel failed: \(message)", level: .error, session: session.name)
            scheduleReconnectIfNeeded(id: tunnel.id)
        }
    }

    private func handleTunnelExit(id: UUID, process: Process, status: Int32, message: String?) {
        guard activeTunnels[id] === process else { return }
        activeTunnels.removeValue(forKey: id)
        guard requestedTunnels[id] != nil else { return }
        let detail = message?.isEmpty == false ? message! : "ssh exited with status \(status)"
        tunnelErrors[id] = detail
        if let session = requestedTunnels[id]?.1 {
            ConnectionLog.shared.log("Tunnel disconnected: \(detail)", level: .warning, session: session.name)
        }
        scheduleReconnectIfNeeded(id: id)
    }

    private func scheduleReconnectIfNeeded(id: UUID) {
        guard let (tunnel, session) = requestedTunnels[id], tunnel.autoReconnect else { return }
        reconnectTasks[id]?.cancel()
        reconnectTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.requestedTunnels[id] != nil else { return }
            self.reconnectTasks[id] = nil
            self.launchTunnel(tunnel: tunnel, session: session)
        }
    }
}

private extension TunnelConfig {
    var nameOrFallback: String { name.isEmpty ? "Tunnel" : name }
}
