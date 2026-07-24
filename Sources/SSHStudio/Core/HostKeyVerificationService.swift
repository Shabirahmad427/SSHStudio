import Foundation

protocol HostKeyVerificationServicing: Sendable {
    func evaluate(endpoint: SSHHostEndpoint) async -> SSHHostTrustState
    func approve(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord
    func reject(endpoint: SSHHostEndpoint) async
}

actor HostKeyVerificationService: HostKeyVerificationServicing {
    private let store: HostKeyStore
    private let discovery: HostKeyDiscovery
    private let configResolver: SSHConfigResolving
    private var activeChecks: [String: Task<SSHHostTrustState, Never>] = [:]

    init(
        store: HostKeyStore = ManagedHostKeyStore(),
        discovery: HostKeyDiscovery = SSHKeyscanProcessAdapter(),
        configResolver: SSHConfigResolving = OpenSSHConfigResolver()
    ) {
        self.store = store
        self.discovery = discovery
        self.configResolver = configResolver
    }

    func evaluate(endpoint: SSHHostEndpoint) async -> SSHHostTrustState {
        if let existing = activeChecks[endpoint.key] {
            return await existing.value
        }
        let task = Task<SSHHostTrustState, Never> {
            await evaluateUncoalesced(endpoint: endpoint)
        }
        activeChecks[endpoint.key] = task
        let result = await task.value
        activeChecks[endpoint.key] = nil
        return result
    }

    func approve(_ candidate: SSHHostKeyCandidate) async throws -> SSHHostKeyRecord {
        if let changed = try await store.detectChangedKey(candidate) {
            throw SSHHostKeyError.store("Refusing to replace existing trust record \(changed.fingerprint.sha256).")
        }
        return try await store.addApprovedKey(candidate)
    }

    func reject(endpoint: SSHHostEndpoint) async {
        activeChecks[endpoint.key]?.cancel()
        activeChecks[endpoint.key] = nil
    }

    private func evaluateUncoalesced(endpoint: SSHHostEndpoint) async -> SSHHostTrustState {
        do {
            if let resolution = await configResolver.resolve(host: endpoint.hostname),
               resolution.requiresOpenSSHManagedVerification {
                return .trustedByOpenSSHConfiguration
            }

            let stored = try await store.lookup(endpoint: endpoint)
            if stored.contains(where: { $0.source == .system }) {
                return .trustedBySystem
            }

            let candidates = try await discovery.scan(endpoint: endpoint)
            guard let presented = candidates.first else {
                return .unavailable("No host keys were presented.")
            }

            if let changed = try await store.detectChangedKey(presented) {
                return .changed(previous: changed, presented: presented)
            }

            if stored.contains(where: {
                $0.source == .sshStudio &&
                $0.algorithm == presented.algorithm &&
                $0.fingerprint == presented.fingerprint
            }) {
                return .trustedBySSHStudio
            }

            for candidate in candidates {
                if let changed = try await store.detectChangedKey(candidate) {
                    return .changed(previous: changed, presented: candidate)
                }
            }

            return .unknown(candidates)
        } catch is CancellationError {
            return .failed(SSHHostKeyError.cancelled.localizedDescription)
        } catch {
            return .failed(DiagnosticRedactor.redact(error.localizedDescription))
        }
    }
}

@MainActor
final class HostKeyVerificationModel: ObservableObject {
    static let shared = HostKeyVerificationModel()

    @Published var pendingState: SSHHostTrustState?
    @Published var pendingEndpoint: SSHHostEndpoint?

    private let service: HostKeyVerificationServicing

    init(service: HostKeyVerificationServicing = HostKeyVerificationService()) {
        self.service = service
    }

    func evaluate(session: Session) async -> SSHHostTrustState {
        let endpoint = SSHHostEndpoint(session: session)
        pendingEndpoint = endpoint
        let state = await service.evaluate(endpoint: endpoint)
        switch state {
        case .unknown, .changed:
            pendingState = state
        default:
            pendingState = nil
        }
        return state
    }

    func approve(candidate: SSHHostKeyCandidate) async throws {
        _ = try await service.approve(candidate)
        pendingState = nil
        pendingEndpoint = nil
    }

    func cancel() async {
        if let endpoint = pendingEndpoint {
            await service.reject(endpoint: endpoint)
        }
        pendingState = nil
        pendingEndpoint = nil
    }
}
