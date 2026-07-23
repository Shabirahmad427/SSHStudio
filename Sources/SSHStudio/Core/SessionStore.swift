import Foundation

@MainActor
class SessionStore: ObservableObject {
    @Published var sessions: [Session] = []

    private let key = "saved_sessions"
    private let defaults = SSHStudioDefaults.shared

    init() {
        load()
    }

    func add(_ session: Session) {
        sessions.append(session)
        save()
    }

    func update(_ session: Session) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        sessions.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Session].self, from: data)
        else { return }
        sessions = decoded
    }

}
