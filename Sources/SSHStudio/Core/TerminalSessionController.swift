import Foundation
import AppKit
import Darwin

enum TerminalLifecycleState: Equatable {
    case idle
    case starting(Date)
    case running(Date)
    case disconnecting(Date, forced: Bool)
    case exited(Date, exitStatus: Int32?, userRequested: Bool)
    case reconnecting(Date)
    case failed(Date, message: String)

    var isRunning: Bool {
        switch self {
        case .starting, .running, .disconnecting, .reconnecting:
            return true
        case .idle, .exited, .failed:
            return false
        }
    }
}

enum TerminalClosePolicy: Equatable {
    case closeImmediately
    case confirmDisconnect(transferCount: Int, tunnelCount: Int, reconnecting: Bool)
}

@MainActor
protocol TerminalProcessControlling: AnyObject {
    var isRunning: Bool { get }
    var processIdentifier: pid_t { get }
    func terminateGracefully()
    func forceTerminate()
    func focusTerminal()
    func findNext(_ term: String) -> Bool
    func findPrevious(_ term: String) -> Bool
    func clearFind()
}

@MainActor
final class TerminalSessionController: ObservableObject {
    let id: UUID
    @Published private(set) var state: TerminalLifecycleState = .idle
    @Published var isFindVisible = false
    @Published var findText = ""
    @Published private(set) var lastExitStatus: Int32?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?

    private weak var processHandle: TerminalProcessControlling?
    private weak var connectionService: SSHConnectionService?
    private var userRequestedDisconnect = false
    private var disconnectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(id: UUID = UUID(), connectionService: SSHConnectionService? = nil) {
        self.id = id
        self.connectionService = connectionService
    }

    func attach(processHandle: TerminalProcessControlling) {
        self.processHandle = processHandle
    }

    func detach(processHandle: TerminalProcessControlling) {
        if self.processHandle === processHandle {
            self.processHandle = nil
        }
    }

    func beginStart() -> Bool {
        switch state {
        case .starting, .running, .disconnecting, .reconnecting:
            return false
        case .idle, .exited, .failed:
            state = .starting(Date())
            return true
        }
    }

    func processStarted() {
        let now = Date()
        startedAt = now
        endedAt = nil
        userRequestedDisconnect = false
        state = .running(now)
        connectionService?.processStarted()
    }

    func processExited(exitStatus: Int32?, message: String? = nil) {
        disconnectTask?.cancel()
        disconnectTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        lastExitStatus = exitStatus
        endedAt = Date()
        state = .exited(endedAt ?? Date(), exitStatus: exitStatus, userRequested: userRequestedDisconnect)
        connectionService?.processTerminated(exitStatus: exitStatus, message: message)
        userRequestedDisconnect = false
    }

    func fail(_ message: String) {
        let safe = DiagnosticRedactor.redact(message)
        state = .failed(Date(), message: safe)
        connectionService?.hostIdentityFailed(safe)
    }

    func disconnect(gracePeriod: TimeInterval = 1.5) {
        reconnectTask?.cancel()
        reconnectTask = nil
        userRequestedDisconnect = true
        connectionService?.userRequestedDisconnect()

        guard let processHandle, processHandle.isRunning else {
            processExited(exitStatus: lastExitStatus, message: "Disconnected")
            return
        }

        state = .disconnecting(Date(), forced: false)
        processHandle.terminateGracefully()
        disconnectTask?.cancel()
        disconnectTask = Task { @MainActor [weak self, weak processHandle] in
            try? await Task.sleep(for: .seconds(gracePeriod))
            guard let self, let processHandle, processHandle.isRunning else { return }
            self.state = .disconnecting(Date(), forced: true)
            processHandle.forceTerminate()
        }
    }

    func reconnect(action: @escaping @MainActor @Sendable () -> Void) {
        disconnectTask?.cancel()
        reconnectTask?.cancel()
        state = .reconnecting(Date())
        connectionService?.scheduleReconnect(attempt: 1, action: action)
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionService?.cancelReconnect()
        state = .exited(Date(), exitStatus: lastExitStatus, userRequested: true)
    }

    func closePolicy(transferCount: Int, tunnelCount: Int) -> TerminalClosePolicy {
        switch state {
        case .idle, .exited, .failed:
            return .closeImmediately
        case .reconnecting:
            return .confirmDisconnect(transferCount: transferCount, tunnelCount: tunnelCount, reconnecting: true)
        case .starting, .running, .disconnecting:
            return .confirmDisconnect(transferCount: transferCount, tunnelCount: tunnelCount, reconnecting: false)
        }
    }

    func focusTerminal() {
        processHandle?.focusTerminal()
    }

    func showFind() {
        isFindVisible = true
        focusTerminal()
    }

    func closeFind() {
        isFindVisible = false
        processHandle?.clearFind()
    }

    @discardableResult
    func findNext() -> Bool {
        guard !findText.isEmpty else { return false }
        return processHandle?.findNext(findText) ?? false
    }

    @discardableResult
    func findPrevious() -> Bool {
        guard !findText.isEmpty else { return false }
        return processHandle?.findPrevious(findText) ?? false
    }
}
