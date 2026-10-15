import Foundation

struct PipelineRepairAttempts {
    private var counts: [String: Int] = [:]

    mutating func record(scope: String, failure: String?) -> Bool {
        guard failure != nil else { counts.removeValue(forKey: scope); return false }
        counts[scope, default: 0] += 1
        return counts[scope, default: 0] >= 3
    }

    mutating func reset() { counts.removeAll() }

    /// A failed write and a write that left the artifact byte-identical both count as no progress.
    static func noProgress(
        isError: Bool,
        errorText: String,
        byteComparison: AgentHostStateRecord.ByteComparison?
    ) -> String? {
        if isError { return errorText }
        if byteComparison == .unchanged {
            return "The writer stored byte-identical content; the artifact did not change."
        }
        return nil
    }

    static func scope(projectRoot: String?, phase: String?, tool: String) -> String {
        "\(projectRoot ?? ""): \(phase ?? tool)"
    }
}
