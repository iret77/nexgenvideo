import Foundation
import SwiftUI

struct AgentActivity: Identifiable {
    struct Step: Identifiable {
        let id: String
        let name: String
        let inputJSON: String
        var thinkingSummaries: [String] = []
    }

    let id: UUID
    let statuses: [String]
    let steps: [Step]
    let isRunning: Bool
    var trailingThinkingSummaries: [String] = []

    var currentStatus: String? { statuses.last }
    var operationLabel: String {
        steps.last.map { ToolRunPresentation.label(for: $0.name) } ?? "Thinking"
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

struct AgentHostState: Identifiable {
    enum Disposition: Equatable {
        case current
        case superseded
        case resetByRevision
    }

    let record: AgentHostStateRecord
    var disposition: Disposition = .current
    var id: UUID { record.id }
}

enum AgentTranscriptItem: Identifiable {
    case userIntent(AgentUserIntent)
    case assistantResult(AgentMessage)
    case activity(AgentActivity)
    case hostState(AgentHostState)
    case receipts(AgentReceiptGroup)
    case notice(AgentNoticeReceipt)

    var id: String {
        switch self {
        case .userIntent(let intent): "intent-\(intent.id.uuidString)"
        case .assistantResult(let message): "result-\(message.id.uuidString)"
        case .activity(let activity): "activity-\(activity.id.uuidString)"
        case .hostState(let state): "host-state-\(state.id.uuidString)"
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
    static func taskItems(messages: [AgentMessage], isStreaming: Bool) -> [AgentTranscriptItem] {
        let streamingID = isStreaming ? messages.last(where: { $0.role == .assistant })?.id : nil
        return messages.flatMap { message -> [AgentTranscriptItem] in
            if message.role == .assistant, !message.hidden {
                var visible = message
                visible.blocks = message.blocks.filter { block in
                    if case .text(let text) = block {
                        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return !message.isIncompleteAPIResponse && isPersistentTool(block)
                }
                var items: [AgentTranscriptItem] = visible.blocks.isEmpty ? [] : [.assistantResult(visible)]
                if message.isIncompleteAPIResponse, message.id != streamingID {
                    items.append(.notice(.init(id: message.id, text: String(localized:
                        "Response interrupted. This partial answer is not included in the agent’s context. Send a new request to continue."))))
                }
                return items
            }
            if let notice = message.userPresentation?.notice?.trimmingCharacters(in: .whitespacesAndNewlines),
               !notice.isEmpty {
                return [.notice(.init(id: message.id, text: notice))]
            }
            return []
        }
    }

    static func turns(messages: [AgentMessage], isStreaming: Bool) -> [AgentTranscriptTurn] {
        HangDiagnosticSelfTest.injectReplayControl(messages)
        let diagnosticID = HangDiagnosticRecorder.shared.record(.projection, values: [Double(messages.count)])
        defer { HangDiagnosticRecorder.shared.record(.projection, correlation: diagnosticID, end: true) }
        let messageTurns = splitIntoTurns(messages)
        let turns = messageTurns.enumerated().compactMap { index, messages in
            project(messages, isRunning: isStreaming && index == messageTurns.count - 1)
        }
        return markingHistoricalHostStates(turns)
    }

    /// Older host states stay visible as history but never read as the current call to action.
    private static func markingHistoricalHostStates(
        _ turns: [AgentTranscriptTurn]
    ) -> [AgentTranscriptTurn] {
        var dispositions: [UUID: AgentHostState.Disposition] = [:]
        var live: [AgentHostState] = []
        for turn in turns {
            for case .hostState(let state) in turn.items {
                if state.record.state == .rewound {
                    let reset = Set(state.record.resetPhases ?? [state.record.phase])
                    live.removeAll { earlier in
                        guard reset.contains(earlier.record.phase) else { return false }
                        dispositions[earlier.id] = .resetByRevision
                        return true
                    }
                }
                live.removeAll { earlier in
                    guard earlier.record.phase == state.record.phase,
                          replaces(state.record.state, earlier: earlier.record.state) else {
                        return false
                    }
                    dispositions[earlier.id] = .superseded
                    return true
                }
                live.append(state)
            }
        }
        guard !dispositions.isEmpty else { return turns }
        return turns.map { turn in
            AgentTranscriptTurn(id: turn.id, items: turn.items.map { item in
                guard case .hostState(var state) = item,
                      let disposition = dispositions[state.id] else { return item }
                state.disposition = disposition
                return .hostState(state)
            })
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
        var hostStates: [AgentHostState] = []
        var receipts: [AgentTranscriptItem] = []
        var notices: [AgentTranscriptItem] = []
        let streamingMessageID = isRunning ? messages.last(where: { $0.role == .assistant })?.id : nil

        for message in messages {
            for hostState in message.hostStateRecords {
                appendHostState(.init(record: hostState), to: &hostStates)
            }
            switch message.role {
            case .user:
                if !message.hidden, let text = authoredText(message) {
                    intents.append(.userIntent(.init(id: message.id, text: text)))
                }
                if let presentation = message.userPresentation {
                    if let hostState = presentation.hostStateRecord {
                        appendHostState(
                            .init(record: hostState),
                            to: &hostStates
                        )
                    }
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
                if message.isIncompleteAPIResponse, message.id != streamingMessageID {
                    notices.append(.notice(.init(
                        id: message.id,
                        text: String(localized: "Response interrupted. This partial answer is not included in the agent’s context. Send a new request to continue.")
                    )))
                }
                let hasActivityTool = message.blocks.contains(where: isActivityTool)
                let persistentBlocks = message.blocks.filter { block in
                    if message.isIncompleteAPIResponse {
                        if case .text = block { return true }
                        return false
                    }
                    switch block {
                    case .thinking, .serverTool: return false
                    default: break
                    }
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
        let stateItems = hostStates.map(AgentTranscriptItem.hostState)
        let output = intents + stateItems + results + activityItems + receipts + notices
        guard !output.isEmpty else { return nil }
        return AgentTranscriptTurn(id: first.id, items: output)
    }

    private static func appendHostState(
        _ state: AgentHostState,
        to output: inout [AgentHostState]
    ) {
        if let exact = output.firstIndex(where: { $0.id == state.id }) {
            output[exact] = state
            return
        }
        if state.record.state != .rewound {
            output.removeAll {
                $0.record.phase == state.record.phase
                    && replaces(state.record.state, earlier: $0.record.state)
            }
        }
        output.append(state)
    }

    static func replaces(
        _ later: AgentHostStateRecord.State,
        earlier: AgentHostStateRecord.State
    ) -> Bool {
        switch later {
        case .approved, .checked, .persisted, .persistedPhaseRecordFailed, .rewound:
            true
        case .writeOutcomeUnavailable:
            earlier != .persistedPhaseRecordFailed
        case .draft, .writeBlocked, .writeRejected, .declined:
            !isCleanDurable(earlier) && !isRepairRequired(earlier)
        case .approvalFailed:
            !isRepairRequired(earlier)
        }
    }

    private static func isCleanDurable(_ state: AgentHostStateRecord.State) -> Bool {
        switch state {
        case .persisted, .checked, .approved: true
        default: false
        }
    }

    private static func isRepairRequired(_ state: AgentHostStateRecord.State) -> Bool {
        switch state {
        case .persistedPhaseRecordFailed, .writeOutcomeUnavailable: true
        default: false
        }
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
        var thinkingSummaries: [String] = []

        for message in turn where message.role == .assistant {
            let hasActivityTool = !message.isIncompleteAPIResponse
                && message.blocks.contains(where: isActivityTool)
            for block in message.blocks {
                switch block {
                case .thinking(let block):
                    if let summary = block.summary { thinkingSummaries.append(summary) }
                case .text(let text):
                    guard hasActivityTool else { continue }
                    let status = compactStatus(text)
                    if !status.isEmpty, statuses.last != status { statuses.append(status) }
                case .toolUse(let id, let name, let inputJSON):
                    guard !message.isIncompleteAPIResponse else { continue }
                    guard ToolRunPresentation.baseName(for: name) != ToolName.showBlocks.rawValue else {
                        continue
                    }
                    steps.append(.init(
                        id: id, name: name, inputJSON: inputJSON,
                        thinkingSummaries: thinkingSummaries
                    ))
                    thinkingSummaries = []
                case .serverTool, .toolResult:
                    break
                }
            }
        }

        guard !steps.isEmpty || !thinkingSummaries.isEmpty else { return nil }
        return AgentActivity(
            id: turn.first?.id ?? UUID(),
            statuses: statuses,
            steps: steps,
            isRunning: isRunning,
            trailingThinkingSummaries: thinkingSummaries
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

enum AgentTaskResultMarker {
    static func lastEarlierResultID(
        items: [AgentTranscriptItem],
        messages: [AgentMessage],
        currentTurnBaseline: UUID?,
        workIsRunning: Bool
    ) -> String? {
        guard workIsRunning else { return nil }
        var earlier: Set<UUID>?
        if let currentTurnBaseline {
            guard let index = messages.firstIndex(where: { $0.id == currentTurnBaseline }) else { return nil }
            earlier = Set(messages[...index].map(\.id))
        }
        return items.last(where: { item in
            guard case .assistantResult(let message) = item else { return false }
            return earlier?.contains(message.id) ?? true
        })?.id
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
