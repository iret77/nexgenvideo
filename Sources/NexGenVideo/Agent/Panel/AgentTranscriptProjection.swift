import Foundation

struct AgentActivity: Identifiable {
    struct Step: Identifiable {
        let id: String
        let name: String
        let inputJSON: String
    }

    let id: UUID
    let statuses: [String]
    let steps: [Step]
    let isRunning: Bool

    var currentStatus: String? { statuses.last }
}

enum AgentTranscriptEntry: Identifiable {
    case message(AgentMessage)
    case activity(AgentActivity)

    var id: String {
        switch self {
        case .message(let message): "message-\(message.id.uuidString)"
        case .activity(let activity): "activity-\(activity.id.uuidString)"
        }
    }
}

enum AgentTranscriptProjection {
    static func entries(messages: [AgentMessage], isStreaming: Bool) -> [AgentTranscriptEntry] {
        let turns = splitIntoTurns(messages)
        return turns.enumerated().flatMap { index, turn in
            project(turn, isRunning: isStreaming && index == turns.count - 1)
        }
    }

    private static func splitIntoTurns(_ messages: [AgentMessage]) -> [[AgentMessage]] {
        var turns: [[AgentMessage]] = []
        var current: [AgentMessage] = []

        for message in messages {
            if isAuthoredUserTurn(message), !current.isEmpty {
                turns.append(current)
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty { turns.append(current) }
        return turns
    }

    private static func project(_ turn: [AgentMessage], isRunning: Bool) -> [AgentTranscriptEntry] {
        let activity = makeActivity(turn, isRunning: isRunning)
        var insertedActivity = false
        var output: [AgentTranscriptEntry] = []

        for message in turn {
            switch message.role {
            case .user:
                if isAuthoredUserTurn(message), !message.hidden {
                    output.append(.message(message))
                }
            case .assistant:
                let hasActivityTool = message.blocks.contains(where: isActivityTool)
                if hasActivityTool, let activity, !insertedActivity {
                    output.append(.activity(activity))
                    insertedActivity = true
                }

                let persistentBlocks = message.blocks.filter { block in
                    guard hasActivityTool else { return true }
                    return isPersistentTool(block)
                }
                if !persistentBlocks.isEmpty {
                    var persistent = message
                    persistent.blocks = persistentBlocks
                    output.append(.message(persistent))
                }
            }
        }

        return output
    }

    private static func makeActivity(_ turn: [AgentMessage], isRunning: Bool) -> AgentActivity? {
        var statuses: [String] = []
        var steps: [AgentActivity.Step] = []

        for message in turn where message.role == .assistant {
            guard message.blocks.contains(where: isActivityTool) else { continue }
            for block in message.blocks {
                switch block {
                case .text(let text):
                    let status = compactStatus(text)
                    if !status.isEmpty, statuses.last != status { statuses.append(status) }
                case .toolUse(let id, let name, let inputJSON):
                    guard ToolRunPresentation.baseName(for: name) != ToolName.showBlocks.rawValue else {
                        continue
                    }
                    steps.append(.init(id: id, name: name, inputJSON: inputJSON))
                case .toolResult:
                    break
                }
            }
        }

        guard !steps.isEmpty else { return nil }
        return AgentActivity(
            id: turn.first?.id ?? UUID(),
            statuses: statuses,
            steps: steps,
            isRunning: isRunning
        )
    }

    private static func isAuthoredUserTurn(_ message: AgentMessage) -> Bool {
        guard message.role == .user else { return false }
        if message.userPresentation != nil { return true }
        return message.blocks.contains {
            if case .text = $0 { return true }
            return false
        }
    }

    private static func isActivityTool(_ block: AgentContentBlock) -> Bool {
        guard case .toolUse(_, let name, _) = block else { return false }
        return ToolRunPresentation.baseName(for: name) != ToolName.showBlocks.rawValue
    }

    private static func isPersistentTool(_ block: AgentContentBlock) -> Bool {
        guard case .toolUse(_, let name, _) = block else { return false }
        return ToolRunPresentation.baseName(for: name) == ToolName.showBlocks.rawValue
    }

    private static func compactStatus(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
