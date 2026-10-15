import Foundation

/// Host-measured time of one chat, split by who was working.
struct AgentWorkTime: Codable, Equatable, Sendable {
    var turnSeconds: Double = 0
    var toolSeconds: Double = 0
    var providerSeconds: Double = 0
    var waitingSeconds: Double = 0
    var failedAttempts: Int = 0

    /// Model time inside agent turns; tool calls run inside those turns.
    var agentSeconds: Double { max(0, turnSeconds - toolSeconds) }

    var isEmpty: Bool { turnSeconds + toolSeconds + providerSeconds + waitingSeconds == 0 && failedAttempts == 0 }

    enum Category: Equatable, Sendable {
        case turn
        case tool
        case provider
        case waiting
    }

    mutating func add(_ seconds: Double, to category: Category) {
        let value = max(0, seconds)
        switch category {
        case .turn: turnSeconds += value
        case .tool: toolSeconds += value
        case .provider: providerSeconds += value
        case .waiting: waitingSeconds += value
        }
    }
}

/// Open intervals that end in a work-time category once their event closes them.
struct AgentWorkTimeIntervals {
    private var open: [String: (sessionID: UUID, category: AgentWorkTime.Category, start: Date)] = [:]

    mutating func begin(_ key: String, sessionID: UUID?, category: AgentWorkTime.Category, at date: Date = Date()) {
        guard let sessionID, open[key] == nil else { return }
        open[key] = (sessionID, category, date)
    }

    mutating func end(_ key: String, at date: Date = Date()) -> (sessionID: UUID, category: AgentWorkTime.Category, seconds: Double)? {
        guard let interval = open.removeValue(forKey: key) else { return nil }
        return (interval.sessionID, interval.category, date.timeIntervalSince(interval.start))
    }

    mutating func rekey(_ old: String, to new: String) {
        guard let interval = open.removeValue(forKey: old) else { return }
        open[new] = interval
    }
}
