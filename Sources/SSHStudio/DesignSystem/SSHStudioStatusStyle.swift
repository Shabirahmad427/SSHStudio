import SwiftUI

struct SSHStudioStatusStyle {
    let title: String
    let systemImage: String
    let color: Color

    static func connection(_ state: SSHConnectionState) -> SSHStudioStatusStyle {
        switch state {
        case .idle:
            return .init(title: "Idle", systemImage: "circle", color: .secondary)
        case .preparing:
            return .init(title: "Preparing", systemImage: "clock", color: .orange)
        case .checkingHostIdentity:
            return .init(title: "Checking Identity", systemImage: "checkmark.shield", color: .orange)
        case .awaitingHostVerification:
            return .init(title: "Awaiting Trust", systemImage: "questionmark.shield", color: .orange)
        case .connecting:
            return .init(title: "Connecting", systemImage: "arrow.triangle.2.circlepath", color: .orange)
        case .authenticating:
            return .init(title: "Authenticating", systemImage: "key", color: .orange)
        case .connected:
            return .init(title: "Connected", systemImage: "checkmark.circle.fill", color: .green)
        case .reconnecting:
            return .init(title: "Reconnecting", systemImage: "arrow.clockwise", color: .orange)
        case .disconnecting:
            return .init(title: "Disconnecting", systemImage: "xmark.circle", color: .yellow)
        case .disconnected:
            return .init(title: "Disconnected", systemImage: "circle", color: .secondary)
        case .failed:
            return .init(title: "Failed", systemImage: "exclamationmark.triangle.fill", color: .red)
        }
    }
}
