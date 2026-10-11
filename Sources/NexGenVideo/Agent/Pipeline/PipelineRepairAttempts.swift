import Foundation

struct PipelineRepairAttempts {
    private var counts: [String: Int] = [:]

    mutating func record(scope: String, failure: String?) -> Bool {
        guard failure != nil else { counts.removeValue(forKey: scope); return false }
        counts[scope, default: 0] += 1
        return counts[scope, default: 0] >= 3
    }

    mutating func reset() { counts.removeAll() }
}
