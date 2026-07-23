import Foundation

@MainActor
enum HostKeyVerificationGate {
    static func allowConnection(session: Session) async -> Result<Void, SSHHostKeyError> {
        let state = await HostKeyVerificationModel.shared.evaluate(session: session)
        switch state {
        case .trustedBySystem, .trustedBySSHStudio:
            return .success(())
        case .unknown:
            return .failure(.store("Host verification is required before connecting."))
        case .changed:
            return .failure(.changed)
        case .failed(let message), .unavailable(let message):
            return .failure(.store(message))
        default:
            return .failure(.store("Host verification did not complete."))
        }
    }
}
