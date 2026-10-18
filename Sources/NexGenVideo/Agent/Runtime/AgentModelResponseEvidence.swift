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
}

struct HostAgentReviewEvidence: Codable, Sendable, Equatable {
    let projectGenerationID: UUID
    let chatSessionID: UUID
    let runtimeGenerationID: UUID
    let logicalTurnID: UUID
    let inputMessageID: UUID
    let response: AgentModelResponseEvidence
}
