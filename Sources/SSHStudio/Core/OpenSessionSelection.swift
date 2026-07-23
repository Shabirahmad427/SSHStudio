import Foundation

enum OpenSessionSelection {
    @MainActor
    static func existingOpenID<S: Sequence>(for session: Session, in openSessions: S) -> UUID?
        where S.Element == OpenSession {
        openSessions.first { $0.session.id == session.id }?.id
    }

    static func existingSessionID(for session: Session, in sessions: [Session]) -> UUID? {
        sessions.first { $0.id == session.id }?.id
    }
}
