import BpyRuntimeProtocol
import Foundation

nonisolated final class BpyStagingCleanup: @unchecked Sendable {
    private struct Pending {
        let url: URL
        let completion: @Sendable () -> Void
    }
    static let shared = BpyStagingCleanup()
    private let queue = DispatchQueue(label: "de.h5ventures.nexgenvideo.bpy.staging.cleanup", qos: .utility)
    private var pending: [UUID: Pending] = [:]
    private var timer: DispatchSourceTimer?

    func discard(_ url: URL, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            pending[UUID()] = Pending(url: url, completion: completion)
            retry()
            guard !pending.isEmpty, timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.retry() }
            self.timer = timer
            timer.resume()
        }
    }

    private func retry() {
        for (id, item) in pending {
            do {
                try BpyRuntimeFile.discardOwned(at: item.url, completion: item.completion)
                pending.removeValue(forKey: id)
            } catch { }
        }
        if pending.isEmpty { timer?.cancel(); timer = nil }
    }
}
