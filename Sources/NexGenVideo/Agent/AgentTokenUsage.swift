import Foundation

/// Provider-reported tokens of one chat, summed over its API requests.
struct AgentTokenUsage: Codable, Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheCreationInputTokens = 0
    var cacheReadInputTokens = 0

    init() {}

    var promptTokens: Int { inputTokens + cacheCreationInputTokens + cacheReadInputTokens }

    var cacheReadShare: Double? {
        promptTokens > 0 ? Double(cacheReadInputTokens) / Double(promptTokens) : nil
    }

    var isEmpty: Bool { promptTokens + outputTokens == 0 }

    mutating func add(_ usage: AgentRuntimeUsage) {
        inputTokens += max(0, usage.inputTokens ?? 0)
        outputTokens += max(0, usage.outputTokens ?? 0)
        cacheCreationInputTokens += max(0, usage.cacheCreationInputTokens ?? 0)
        cacheReadInputTokens += max(0, usage.cacheReadInputTokens ?? 0)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationInputTokens, cacheReadInputTokens
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
        cacheReadInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    }
}

/// Folds the partial usage events of one API request into its final count.
struct AgentRequestUsageMeter {
    private var pending: AgentRuntimeUsage?

    /// The finished request's usage once an event closes it: a new request or the turn's end.
    mutating func observe(_ event: AgentRuntimeEvent) -> AgentRuntimeUsage? {
        switch event {
        case .usage(let usage):
            pending = pending?.merging(usage) ?? usage
            return nil
        case .providerRequest, .terminal:
            return flush()
        default:
            return nil
        }
    }

    mutating func flush() -> AgentRuntimeUsage? {
        defer { pending = nil }
        return pending
    }
}
