import Foundation

class NavigationHistory<T: Equatable>: ObservableObject {
    @Published private(set) var current: T
    private var back: [T] = []
    private var forward: [T] = []

    init(initial: T) { current = initial }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    func navigate(to path: T) {
        guard path != current else { return }
        back.append(current)
        forward.removeAll()
        current = path
    }

    func reset(to path: T) {
        current = path
        back.removeAll()
        forward.removeAll()
    }

    func goBack() {
        guard let prev = back.popLast() else { return }
        forward.append(current)
        current = prev
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }
}
