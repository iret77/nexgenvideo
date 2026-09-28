import Foundation

enum ToolCallOrigin: Hashable, Sendable {
    enum SuspensionKey: Hashable, Sendable {
        case inAppChat(UUID)
        case mcpSession(UUID)
    }

    case direct
    case inAppChat(sessionID: UUID)
    case embeddedRuntime(chatSessionID: UUID, runtimeGenerationID: UUID)
    case externalMCP(sessionID: UUID)

    var chatSessionID: UUID? {
        switch self {
        case .inAppChat(let sessionID): sessionID
        case .embeddedRuntime(let chatSessionID, _): chatSessionID
        case .direct, .externalMCP: nil
        }
    }

    var suspensionKey: SuspensionKey? {
        switch self {
        case .direct: nil
        case .inAppChat(let sessionID): .inAppChat(sessionID)
        case .embeddedRuntime(_, let runtimeGenerationID):
            .mcpSession(runtimeGenerationID)
        case .externalMCP(let sessionID): .mcpSession(sessionID)
        }
    }
}

struct AgentHostTurnReference: Hashable, Sendable {
    let projectGenerationID: UUID
    let chatSessionID: UUID
    let runtimeGenerationID: UUID
    let logicalTurnID: UUID
    let inputMessageID: UUID
}
