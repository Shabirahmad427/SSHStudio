import Foundation

enum SSHConnectionState: Equatable {
    case idle
    case preparing(Date)
    case checkingHostIdentity(SSHHostEndpoint)
    case connecting(Date)
    case awaitingHostVerification(SSHHostEndpoint)
    case authenticating
    case connected(Date)
    case reconnecting(attempt: Int, nextAttempt: Date)
    case disconnecting
    case disconnected(Date, exitStatus: Int32?)
    case failed(Date, message: String)

    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .checkingHostIdentity: return "Checking host"
        case .connecting: return "Connecting"
        case .awaitingHostVerification: return "Host verification"
        case .authenticating: return "Authenticating"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        }
    }

    var safeDetail: String? {
        switch self {
        case .checkingHostIdentity(let endpoint):
            return DiagnosticRedactor.redact("Checking \(endpoint.displayName)", sensitiveValues: [endpoint.displayName])
        case .awaitingHostVerification(let endpoint):
            return DiagnosticRedactor.redact("Verify \(endpoint.displayName)", sensitiveValues: [endpoint.displayName])
        case .reconnecting(let attempt, let next):
            return "Attempt \(attempt), next \(next.formatted(date: .omitted, time: .standard))"
        case .disconnected(_, let status):
            return status.map { "Exited with status \($0)" }
        case .failed(_, let message):
            return message
        default:
            return nil
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .checkingHostIdentity, .connecting, .awaitingHostVerification, .authenticating, .connected, .reconnecting, .disconnecting:
            return true
        case .idle, .disconnected, .failed:
            return false
        }
    }
}

struct SSHReconnectPolicy: Equatable {
    var maxAttempts: Int = 5
    var initialDelay: TimeInterval = 1
    var maxDelay: TimeInterval = 30

    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, initialDelay * pow(2, Double(max(0, attempt - 1))))
    }
}

@MainActor
final class SSHConnectionService: ObservableObject {
    @Published private(set) var state: SSHConnectionState = .idle
    @Published private(set) var events: [DiagnosticEvent] = []

    private var reconnectTask: Task<Void, Never>?
    private var isUserDisconnect = false

    func prepare() {
        state = .preparing(Date())
        record(.connection, .debug, "Preparing SSH connection")
    }

    func checkingHostIdentity(_ endpoint: SSHHostEndpoint) {
        state = .checkingHostIdentity(endpoint)
        record(.hostKey, .debug, "Checking host identity")
    }

    func awaitingHostVerification(_ endpoint: SSHHostEndpoint) {
        state = .awaitingHostVerification(endpoint)
        record(.hostKey, .warning, "Awaiting host verification")
    }

    func hostIdentityFailed(_ message: String) {
        state = .failed(Date(), message: DiagnosticRedactor.redact(message))
        record(.hostKey, .error, message)
    }

    func processStarted() {
        isUserDisconnect = false
        state = .connecting(Date())
        state = .connected(Date())
        record(.connection, .info, "SSH process started")
    }

    func userRequestedDisconnect() {
        isUserDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .disconnecting
        record(.connection, .info, "Disconnect requested")
    }

    func processTerminated(exitStatus: Int32?, message: String?) {
        reconnectTask?.cancel()
        reconnectTask = nil
        let safeMessage = DiagnosticRedactor.redact(message ?? "")
        if isUserDisconnect {
            state = .disconnected(Date(), exitStatus: exitStatus)
            record(.connection, .info, "SSH process disconnected")
        } else if exitStatus == 0 {
            state = .disconnected(Date(), exitStatus: exitStatus)
            record(.connection, .info, "SSH process exited")
        } else {
            state = .failed(Date(), message: safeMessage.isEmpty ? "SSH process failed" : safeMessage)
            record(.connection, .error, safeMessage.isEmpty ? "SSH process failed" : safeMessage)
        }
        isUserDisconnect = false
    }

    func scheduleReconnect(policy: SSHReconnectPolicy = SSHReconnectPolicy(),
                           attempt: Int = 1,
                           action: @escaping @MainActor @Sendable () -> Void) {
        guard attempt <= policy.maxAttempts else {
            state = .failed(Date(), message: "Reconnect attempts exhausted")
            record(.connection, .error, "Reconnect attempts exhausted")
            return
        }
        reconnectTask?.cancel()
        let delay = policy.delay(forAttempt: attempt)
        let next = Date().addingTimeInterval(delay)
        state = .reconnecting(attempt: attempt, nextAttempt: next)
        record(.connection, .warning, "Reconnect scheduled")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            action()
        }
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .disconnected(Date(), exitStatus: nil)
        record(.connection, .info, "Reconnect cancelled")
    }

    private func record(_ category: DiagnosticCategory, _ severity: DiagnosticSeverity, _ message: String) {
        let event = DiagnosticEvent(category: category, severity: severity, message: message)
        events.insert(event, at: 0)
        events = Array(events.prefix(200))
    }
}
