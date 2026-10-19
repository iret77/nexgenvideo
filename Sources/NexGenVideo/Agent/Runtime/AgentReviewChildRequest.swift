import Foundation

enum AgentReviewChildKind: String, Codable, Equatable, Sendable {
    case page, reducer, synthesis
}

struct AgentReviewChildBinding: Equatable, Sendable {
    let originalChatID: UUID
    let projectID: String
    let projectGenerationID: UUID
    let workingCopyKey: String
    let workingCopyGeneration: UUID
    let projectRoot: URL
    let dataRoot: URL
    let trustedDeclaration: ProjectPackGate.MutationDeclaration
    let workflow: HostWorkflowKey
    let mutationLeaseID: UUID
}

struct AgentReviewChildBounds: Codable, Equatable, Sendable {
    let maximumRequests: Int
    let maximumRequestBytes: Int
    let maximumToolResultBytes: Int
    let maximumEstimatedInputTokens: Int
    let maximumOutputTokens: Int
    let maximumMCPOutputTokens: Int
    let maximumTurns: Int

    func validate() throws {
        guard [maximumRequests, maximumRequestBytes, maximumToolResultBytes,
               maximumEstimatedInputTokens, maximumOutputTokens, maximumMCPOutputTokens,
               maximumTurns].allSatisfy({ $0 > 0 }) else {
            throw ToolError("The review context has invalid resource bounds.")
        }
    }
}

struct AgentReviewChildRequest: Sendable {
    let runID: UUID
    let authID: UUID
    let manifestID: String
    let pageID: String
    let kind: AgentReviewChildKind
    let phase: String
    let binding: AgentReviewChildBinding
    let backend: AgentBackend
    let modelID: String?
    let hostContext: AgentRuntimeHostContext
    let bootstrap: String
    let bounds: AgentReviewChildBounds

    static let readTool = "get_render_review_page"
    static let writeTool = "write_render_review_page"

    func validate() throws {
        try bounds.validate()
        guard backend == .claudeCode || backend == .anthropicAPI,
              !manifestID.isEmpty, !pageID.isEmpty, !bootstrap.isEmpty,
              bootstrap.utf8.count <= bounds.maximumRequestBytes,
              binding.workflow.isProductionV2,
              phase == "render_review",
              hostContext.pack.map({ $0.currentPhase == phase }) ?? true,
              Set(hostContext.toolSchemas.map(\.name)) == [Self.readTool, Self.writeTool],
              hostContext.toolSchemas.count == 2,
              modelID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? (backend == .claudeCode)
        else { throw ToolError("The review child does not match the authorized phase context.") }
    }
}

typealias AgentReviewChildToolHandler = @MainActor @Sendable (
    _ toolName: String, _ canonicalJSON: String, _ evidence: AgentReviewChildCallEvidence
) async throws -> ToolResult

struct AgentReviewChildProgress: Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case starting, reading, recording, stopping, completed, cancelled, failed
    }
    let runID: UUID
    let pageID: String
    let kind: AgentReviewChildKind
    let stage: Stage
    let modelID: String?
}

struct AgentReviewChildCompletion: Equatable, Sendable {
    let runID: UUID
    let authID: UUID
    let manifestID: String
    let pageID: String
    let generationID: UUID
    let modelID: String
    let calls: [AgentReviewChildCallEvidence]
    let usage: AgentRuntimeUsage
}
