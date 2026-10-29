import Foundation

@MainActor
final class ProjectOpenAdmission {
    private(set) var isConfirmedTermination = false
    private var tasks: [UUID: Task<VideoProject?, Error>] = [:]
    private var publications = Set<UUID>()
    private var publicationWaiters: [CheckedContinuation<Void, Never>] = []

    var canOpen: Bool { !isConfirmedTermination }

    func requireOpen() throws {
        try Task.checkCancellation()
        guard canOpen else { throw CancellationError() }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> VideoProject?) async throws -> VideoProject? {
        try requireOpen()
        let id = UUID()
        let task = Task { @MainActor in
            try self.requireOpen()
            return try await operation()
        }
        tasks[id] = task
        defer { tasks.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func confirmTerminationAndDrain() async {
        isConfirmedTermination = true
        let pending = Array(tasks.values)
        pending.forEach { $0.cancel() }
        for task in pending { _ = await task.result }
        if !publications.isEmpty {
            await withCheckedContinuation { publicationWaiters.append($0) }
        }
    }

    func beginPublication() throws -> UUID {
        try requireOpen()
        let id = UUID()
        publications.insert(id)
        return id
    }

    func finishPublication(_ id: UUID) {
        publications.remove(id)
        if publications.isEmpty {
            let waiting = publicationWaiters
            publicationWaiters.removeAll()
            waiting.forEach { $0.resume() }
        }
    }
}
