import Foundation
import SwiftUI

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
    var operationLabel: String {
        steps.last.map { ToolRunPresentation.label(for: $0.name) } ?? "Working"
    }
}

struct AgentUserIntent: Identifiable {
    let id: UUID
    let text: String
}

struct AgentTranscriptReceipt: Identifiable {
    enum Content {
        case choice(AgentChoiceRecord)
        case workflow(AgentWorkflowRecord)
    }

    let id: UUID
    let content: Content
}

struct AgentReceiptGroup: Identifiable {
    let id: UUID
    let phase: String?
    var receipts: [AgentTranscriptReceipt]
}

struct AgentNoticeReceipt: Identifiable {
    let id: UUID
    let text: String
}

enum AgentTranscriptItem: Identifiable {
    case userIntent(AgentUserIntent)
    case assistantResult(AgentMessage)
    case activity(AgentActivity)
    case receipts(AgentReceiptGroup)
    case notice(AgentNoticeReceipt)

    var id: String {
        switch self {
        case .userIntent(let intent): "intent-\(intent.id.uuidString)"
        case .assistantResult(let message): "result-\(message.id.uuidString)"
        case .activity(let activity): "activity-\(activity.id.uuidString)"
        case .receipts(let group): "receipts-\(group.id.uuidString)"
        case .notice(let notice): "notice-\(notice.id.uuidString)"
        }
    }
}

struct AgentTranscriptTurn: Identifiable {
    let id: UUID
    let items: [AgentTranscriptItem]
}

enum AgentTranscriptProjection {
    static func turns(messages: [AgentMessage], isStreaming: Bool) -> [AgentTranscriptTurn] {
        let messageTurns = splitIntoTurns(messages)
        return messageTurns.enumerated().compactMap { index, messages in
            project(messages, isRunning: isStreaming && index == messageTurns.count - 1)
        }
    }

    private static func splitIntoTurns(_ messages: [AgentMessage]) -> [[AgentMessage]] {
        var turns: [[AgentMessage]] = []
        var current: [AgentMessage] = []

        for message in messages {
            if beginsTurn(message), !current.isEmpty {
                turns.append(current)
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty { turns.append(current) }
        return turns
    }

    private static func project(
        _ messages: [AgentMessage],
        isRunning: Bool
    ) -> AgentTranscriptTurn? {
        guard let first = messages.first else { return nil }
        let activity = makeActivity(messages, isRunning: isRunning)
        var intents: [AgentTranscriptItem] = []
        var resultMessage: AgentMessage?
        var receipts: [AgentTranscriptItem] = []
        var notices: [AgentTranscriptItem] = []

        for message in messages {
            switch message.role {
            case .user:
                if !message.hidden, let text = authoredText(message) {
                    intents.append(.userIntent(.init(id: message.id, text: text)))
                }
                if let presentation = message.userPresentation {
                    if let workflow = presentation.workflowRecord {
                        appendReceipt(
                            .init(id: message.id, content: .workflow(workflow)),
                            phase: workflow.phase,
                            to: &receipts
                        )
                    }
                    if let choice = presentation.choiceRecord {
                        appendReceipt(
                            .init(id: message.id, content: .choice(choice)),
                            phase: nil,
                            to: &receipts
                        )
                    }
                    if let notice = presentation.notice?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ), !notice.isEmpty {
                        notices.append(.notice(.init(id: message.id, text: notice)))
                    }
                }
            case .assistant:
                let hasActivityTool = message.blocks.contains(where: isActivityTool)
                let persistentBlocks = message.blocks.filter { block in
                    guard hasActivityTool else { return true }
                    return isPersistentTool(block)
                }
                if !persistentBlocks.isEmpty {
                    if resultMessage == nil {
                        var persistent = message
                        persistent.blocks = persistentBlocks
                        resultMessage = persistent
                    } else {
                        resultMessage?.blocks.append(contentsOf: persistentBlocks)
                    }
                }
            }
        }

        let activityItems = activity.map { [AgentTranscriptItem.activity($0)] } ?? []
        let results = resultMessage.map { [AgentTranscriptItem.assistantResult($0)] } ?? []
        let output = intents + results + activityItems + receipts + notices
        guard !output.isEmpty else { return nil }
        return AgentTranscriptTurn(id: first.id, items: output)
    }

    private static func appendReceipt(
        _ receipt: AgentTranscriptReceipt,
        phase: String?,
        to output: inout [AgentTranscriptItem]
    ) {
        if case .receipts(var group)? = output.last, group.phase == phase {
            group.receipts.append(receipt)
            output[output.count - 1] = .receipts(group)
        } else {
            output.append(.receipts(.init(
                id: receipt.id,
                phase: phase,
                receipts: [receipt]
            )))
        }
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

    private static func beginsTurn(_ message: AgentMessage) -> Bool {
        guard message.role == .user else { return false }
        if message.hidden {
            return message.blocks.contains {
                guard case .text(let text) = $0 else { return false }
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        return authoredText(message) != nil
    }

    private static func authoredText(_ message: AgentMessage) -> String? {
        if let typed = message.userPresentation?.typedText?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !typed.isEmpty {
            return typed
        }
        guard message.userPresentation == nil else { return nil }
        let text = message.blocks.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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

enum AgentTranscriptScrollPolicy {
    static let endID = "transcript-end"

    static func pinState(
        for phase: ScrollPhase,
        suppressProgrammaticUpdate: Bool,
        contentHeight: CGFloat,
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        threshold: CGFloat
    ) -> Bool? {
        if suppressProgrammaticUpdate && (phase == .animating || phase == .idle) {
            return nil
        }
        guard phase == .interacting || phase == .decelerating || phase == .idle else {
            return nil
        }
        return isAwayFromBottom(
            contentHeight: contentHeight,
            contentOffsetY: contentOffsetY,
            containerHeight: containerHeight,
            threshold: threshold
        )
    }

    static func isAwayFromBottom(
        contentHeight: CGFloat,
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        contentHeight - contentOffsetY - containerHeight > threshold
    }
}
