import Foundation
import Observation

@MainActor @Observable
final class ExportPreparation {
    private(set) var isPreparing = false
    private(set) var isCancelling = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestID: String?
    @ObservationIgnored private let cancelJob: (String) -> Void

    init(cancelJob: @escaping (String) -> Void) { self.cancelJob = cancelJob }

    func start(_ operation: @escaping @MainActor (String) async throws -> Void,
               failure: @escaping @MainActor (Error) -> Void) {
        guard task == nil else { return }
        let id = UUID().uuidString.lowercased()
        requestID = id
        isPreparing = true
        isCancelling = false
        task = Task { @MainActor in
            defer {
                task = nil; requestID = nil
                isPreparing = false; isCancelling = false
            }
            do {
                try Task.checkCancellation()
                try await operation(id)
                try Task.checkCancellation()
            } catch { failure(Task.isCancelled ? CancellationError() : error) }
        }
    }

    func cancel() {
        guard let task, let requestID else { return }
        isCancelling = true
        task.cancel()
        cancelJob(requestID)
    }
}
