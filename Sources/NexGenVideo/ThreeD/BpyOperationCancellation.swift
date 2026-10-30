import Foundation

nonisolated final class BpyOperationCancellation: @unchecked Sendable {
    final class Registration: @unchecked Sendable {
        private let remove: @Sendable () -> Void
        init(remove: @escaping @Sendable () -> Void) { self.remove = remove }
        deinit { remove() }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var parents: [Registration] = []
    let id = UUID()

    var isCancelled: Bool { lock.withLock { cancelled } }

    func check() throws {
        if isCancelled { throw BpyAdmissionFailure.cancelled }
    }

    func observe(_ action: @escaping @Sendable () -> Void) -> Registration {
        let id = UUID()
        let immediate = lock.withLock {
            if cancelled { return true }
            observers[id] = action
            return false
        }
        if immediate { action() }
        return Registration { [weak self] in _ = self?.lock.withLock { self?.observers.removeValue(forKey: id) } }
    }

    func follow(_ parent: BpyOperationCancellation) {
        guard parent !== self else { return }
        let registration = parent.observe { [weak self] in self?.cancel() }
        _ = lock.withLock {
            guard !cancelled else { return false }
            parents.append(registration)
            return true
        }
    }

    func cancel() {
        let pending = lock.withLock { () -> ([@Sendable () -> Void], [Registration]) in
            guard !cancelled else { return ([], []) }
            cancelled = true
            let actions = Array(observers.values)
            observers.removeAll()
            let links = parents; parents.removeAll()
            return (actions, links)
        }
        for action in pending.0 { action() }
        withExtendedLifetime(pending.1) {}
    }
}
