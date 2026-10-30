import BpyRuntimeProtocol
import Foundation

nonisolated final class BpyObservedActivity: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID()
    private let parent: UUID?
    private let scope: String
    private var token: NSObjectProtocol?

    init(options: ProcessInfo.ActivityOptions, reason: String, parent: UUID? = nil) {
        self.parent = parent; scope = reason
        token = ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        super.init()
        BpyRuntimeObservation.shared.activity(id: id, parent: parent, scope: scope, event: "begin")
    }

    static func begin(options: ProcessInfo.ActivityOptions, reason: String, parent: UUID? = nil) -> NSObjectProtocol {
        BpyObservedActivity(options: options, reason: reason, parent: parent)
    }

    static func end(_ token: NSObjectProtocol) {
        if let observed = token as? BpyObservedActivity { observed.end() }
        else { ProcessInfo.processInfo.endActivity(token) }
    }

    func end() {
        let owned = lock.withLock { let value = token; token = nil; return value }
        guard let owned else { return }
        ProcessInfo.processInfo.endActivity(owned)
        BpyRuntimeObservation.shared.activity(id: id, parent: parent, scope: scope, event: "end")
    }

    deinit { end() }
}
