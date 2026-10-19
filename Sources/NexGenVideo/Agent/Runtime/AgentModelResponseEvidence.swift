import Foundation
import NexGenEngine

struct AgentModelResponseEvidence: Codable, Sendable, Equatable {
    let sessionID: UUID
    let turnID: UUID
    let messageID: String
    let modelID: String
    let toolUseID: String
    let toolName: String
    let toolInputSHA256: String
    let toolInputJSON: String

    init(sessionID: UUID, turnID: UUID, messageID: String, modelID: String,
         toolUseID: String, toolName: String = "", inputJSON: String) throws {
        self.sessionID = sessionID
        self.turnID = turnID
        self.messageID = messageID
        self.modelID = modelID
        self.toolUseID = toolUseID
        self.toolName = toolName
        let object = try JSONSerialization.jsonObject(with: Data(inputJSON.utf8))
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        toolInputJSON = String(decoding: bytes, as: UTF8.self)
        toolInputSHA256 = FileDigest.sha256(of: bytes)
    }

    static func inputHash(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return FileDigest.sha256(of: try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    func matchesHostTool(_ name: String) -> Bool {
        toolName == name || toolName == "mcp__nexgen__\(name)"
    }

    func requireHostCall(tool name: String, origin: ToolCallOrigin, turn: AgentHostTurnReference,
                         toolUseID: String, arguments: [String: Any]) throws {
        let expectedName: String
        switch origin {
        case .embeddedRuntime(let chatID, let generationID):
            guard chatID == turn.chatSessionID, generationID == turn.runtimeGenerationID else {
                throw ToolError("The review call belongs to another runtime session.")
            }
            expectedName = "mcp__nexgen__\(name)"
        case .inAppChat(let chatID):
            guard chatID == turn.chatSessionID else { throw ToolError("The review call belongs to another chat session.") }
            expectedName = name
        case .direct, .externalMCP:
            throw ToolError("The review call has no originating host runtime.")
        }
        guard self.toolUseID == toolUseID, !toolUseID.isEmpty, toolName == expectedName,
              sessionID == turn.chatSessionID, turnID == turn.logicalTurnID,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !messageID.isEmpty else {
            throw ToolError("The review response does not match its originating model tool call.")
        }
        guard JSONSerialization.isValidJSONObject(arguments) else { throw ToolError("The review arguments must contain valid JSON values.") }
        let bytes = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
        guard toolInputSHA256 == (try Self.inputHash(String(decoding: bytes, as: UTF8.self))) else {
            throw ToolError("The review arguments differ from the model's recorded tool response.")
        }
    }
}

struct HostAgentReviewEvidence: Codable, Sendable, Equatable {
    let projectGenerationID: UUID
    let chatSessionID: UUID
    let runtimeGenerationID: UUID
    let logicalTurnID: UUID
    let inputMessageID: UUID
    let response: AgentModelResponseEvidence
}
