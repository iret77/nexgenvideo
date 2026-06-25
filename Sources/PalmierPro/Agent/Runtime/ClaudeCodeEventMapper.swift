import Foundation

// Reduces the decoded stream-json events of one `claude -p` session into the editor's existing
// `AgentMessage` render model, so the embedded Claude Code runtime renders in the same agent panel
// as the in-app agent — no changes to AgentPanelView / AgentMessageView.
//
// Pure value type: feed it lines/events, read back `messages`. The runtime owns one instance and
// publishes `messages` to the @Observable service. Tool execution happens inside the CLI (via MCP),
// so this only translates what the stream reports — it never executes anything.

struct ClaudeCodeEventMapper {

    private(set) var messages: [AgentMessage] = []
    /// Session id from `system/init`, used to `--resume` the conversation on the next turn.
    private(set) var sessionId: String?
    /// `total_cost_usd` reported by the most recent `result` line.
    private(set) var lastTurnCostUSD: Double?
    /// Non-nil when the most recent turn ended in error.
    private(set) var turnError: String?

    // claude assistant message id → index of the AgentMessage it maps to.
    private var assistantIndexByMessageId: [String: Int] = [:]

    mutating func ingest(line: String) {
        for event in ClaudeStreamDecoder.decode(line: line) { ingest(event) }
    }

    /// Append the user's own message (the stream does not echo it). Keeps `messages` the single,
    /// correctly-ordered source of truth for the whole conversation.
    mutating func appendUserText(_ text: String) {
        messages.append(AgentMessage(role: .user, blocks: [.text(text)]))
    }

    /// Append a runtime-level note (e.g. "Claude Code CLI not found") as an assistant message.
    mutating func appendNote(_ text: String) {
        messages.append(AgentMessage(role: .assistant, blocks: [.text(text)]))
    }

    mutating func ingest(_ event: ClaudeStreamEvent) {
        switch event {
        case .sessionStarted(let sid):
            sessionId = sid

        case .assistantBlock(let messageId, let block):
            appendAssistantBlock(messageId: messageId, block: block)

        case .toolResult(let toolUseId, let blocks, let isError):
            // Mirror the in-app loop: tool results live in a following user message.
            messages.append(AgentMessage(
                role: .user,
                blocks: [.toolResult(toolUseId: toolUseId, content: blocks, isError: isError)]
            ))

        case .turnFinished(let isError, let message, let cost):
            lastTurnCostUSD = cost
            turnError = isError ? (message ?? "Claude Code turn failed.") : nil
        }
    }

    private mutating func appendAssistantBlock(messageId: String, block: ClaudeBlock) {
        let mapped: AgentContentBlock
        switch block {
        case .text(let text):
            mapped = .text(text)
        case .toolUse(let id, let name, let inputJSON):
            mapped = .toolUse(id: id, name: name, inputJSON: inputJSON)
        }

        if let index = assistantIndexByMessageId[messageId] {
            messages[index].blocks.append(mapped)
        } else {
            messages.append(AgentMessage(role: .assistant, blocks: [mapped]))
            assistantIndexByMessageId[messageId] = messages.count - 1
        }
    }
}
