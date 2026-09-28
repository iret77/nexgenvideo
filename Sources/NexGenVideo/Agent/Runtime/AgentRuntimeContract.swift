import Foundation

struct AgentBackendID: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let claudeCode = AgentBackendID(rawValue: "claude-code")
    static let anthropicAPI = AgentBackendID(rawValue: "anthropic-api")
}

struct AgentRuntimeIdentity: Hashable, Sendable {
    let backendID: AgentBackendID
    let displayName: String
}

enum AgentRuntimeAuthentication: Hashable, Sendable {
    case apiKey(service: String)
    case externalSubscription(command: String)
}

enum AgentRuntimeOperation: String, Hashable, Sendable {
    case streamText
    case submitImages
    case resumeFromTranscript
    case resumeNativeSession
    case reportTokenUsage
    case reportCostUsage
    case executeHostTools
    case structuredDialogs
    case approvalSuspension
    case hiddenMessages
    case localizedInstructions
    case phaseInstructions
    case externalClaudeCodePlugins
    case readProjectFiles
    case webResearch
}

enum AgentToolExecutionTransport: Equatable, Sendable {
    case hostRoundTrip
    case providerManagedMCP
}

struct AgentRuntimeCapabilities: Equatable, Sendable {
    let operations: Set<AgentRuntimeOperation>
    let toolNames: Set<String>
    let providerExtensions: Set<String>

    func supports(_ operation: AgentRuntimeOperation) -> Bool {
        operations.contains(operation)
    }
}

struct AgentRuntimeDescriptor: Equatable, Sendable {
    let identity: AgentRuntimeIdentity
    let authentication: AgentRuntimeAuthentication
    let capabilities: AgentRuntimeCapabilities
    let toolExecutionTransport: AgentToolExecutionTransport
}

enum AgentRuntimeState: Equatable, Sendable {
    case idle
    case ready(sessionID: UUID)
    case running(sessionID: UUID, turnID: UUID)
    case cancelling(sessionID: UUID, turnID: UUID)
    case ended(sessionID: UUID)
    case failed(sessionID: UUID?, message: String)
}

enum AgentHostAuthority: String, Hashable, Sendable {
    case toolSchemas
    case toolExecution
    case structuredDialogs
    case outputApprovals
    case gateRefusals
}

struct AgentRuntimeToolSchema: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

struct AgentRuntimeImage: Equatable, Sendable {
    let mediaType: String
    let base64: String
}

enum AgentRuntimeContent: Equatable, Sendable {
    case text(String)
    case image(AgentRuntimeImage)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(id: String, content: [ToolResult.Block], isError: Bool)
}

struct AgentRuntimeMessage: Equatable, Sendable {
    let role: AgentMessage.Role
    let content: [AgentRuntimeContent]
}

struct AgentRuntimePackContext: Equatable, Sendable {
    let id: String
    let version: String
    let projectSchema: String
    let currentPhase: String?
}

struct AgentRuntimeHostContext: Sendable {
    let interfaceLanguage: AgentInterfaceLanguage
    let baseInstructions: String
    let pack: AgentRuntimePackContext?
    let phaseInstructions: String?
    let toolSchemas: [AgentRuntimeToolSchema]
    let authority: Set<AgentHostAuthority>

    var systemInstructions: String {
        var sections = [baseInstructions]
        if let pack {
            var identity = "Format pack: \(pack.id) \(pack.version) (project schema \(pack.projectSchema))."
            if let phase = pack.currentPhase {
                identity += " Current phase: \(phase)."
            } else {
                identity += " The format workflow has no current phase."
            }
            sections.append("# Current project contract\n\(identity)")
        }
        if let phaseInstructions,
           !phaseInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(
                "# Current format-pack phase\n"
                    + "Follow these host-supplied instructions for the current phase:\n\n"
                    + phaseInstructions
            )
        }
        return sections.joined(separator: "\n\n")
    }

    static func hostOwned(
        interfaceLanguage: AgentInterfaceLanguage = .current,
        pack: AgentRuntimePackContext? = nil,
        phaseInstructions: String? = nil,
        tools: [AgentTool] = ToolDefinitions.all
    ) -> AgentRuntimeHostContext {
        AgentRuntimeHostContext(
            interfaceLanguage: interfaceLanguage,
            baseInstructions: AgentInstructions.serverInstructions(language: interfaceLanguage),
            pack: pack,
            phaseInstructions: phaseInstructions,
            toolSchemas: tools.map {
                AgentRuntimeToolSchema(
                    name: $0.name.rawValue,
                    description: $0.description,
                    inputSchema: $0.inputSchema
                )
            },
            authority: [
                .toolSchemas,
                .toolExecution,
                .structuredDialogs,
                .outputApprovals,
                .gateRefusals,
            ]
        )
    }
}

typealias AgentRuntimeToolExecutor = @MainActor @Sendable (
    _ id: String,
    _ name: String,
    _ inputJSON: String
) async -> ToolResult

struct AgentRuntimeSessionRequest: @unchecked Sendable {
    let sessionID: UUID
    let providerSessionID: String?
    let priorMessages: [AgentMessage]
    let hostContext: AgentRuntimeHostContext
    let workingDirectory: URL?
    let pluginDirectories: [URL]
    let providerExtensions: Set<String>
    let mcpPort: Int
    let executeTool: AgentRuntimeToolExecutor
}

struct AgentRuntimeTurnRequest: Sendable {
    let sessionID: UUID
    let turnID: UUID
    /// Canonical provider history, including `currentMessage` exactly once.
    let messages: [AgentRuntimeMessage]
    /// The current input, split out only for stateful providers that already own prior history.
    let currentMessage: AgentRuntimeMessage
}

struct AgentRuntimeUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var costUSD: Double?

    init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        costUSD: Double? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.costUSD = costUSD
    }

    func merging(_ newer: AgentRuntimeUsage) -> AgentRuntimeUsage {
        AgentRuntimeUsage(
            inputTokens: newer.inputTokens ?? inputTokens,
            outputTokens: newer.outputTokens ?? outputTokens,
            cacheCreationInputTokens: newer.cacheCreationInputTokens ?? cacheCreationInputTokens,
            cacheReadInputTokens: newer.cacheReadInputTokens ?? cacheReadInputTokens,
            costUSD: newer.costUSD ?? costUSD
        )
    }
}

enum AgentRuntimeStopReason: String, Equatable, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case pauseTurn
    case refusal
    case other
}

enum AgentRuntimeFailureKind: Equatable, Sendable {
    case authenticationRequired
    case backendUnavailable
    case transport
    case protocolViolation
}

struct AgentRuntimeFailure: Equatable, Sendable {
    let kind: AgentRuntimeFailureKind
    let message: String
}

enum AgentRuntimeTerminal: Equatable, Sendable {
    case completed(AgentRuntimeStopReason)
    case cancelled
    case failed
}

enum AgentRuntimeEvent: Equatable, Sendable {
    case providerSessionStarted(String)
    case providerSessionInvalidated
    case text(messageID: String?, value: String, isDelta: Bool)
    case toolCall(messageID: String?, id: String, name: String, inputJSON: String)
    case toolResult(id: String, content: [ToolResult.Block], isError: Bool)
    case usage(AgentRuntimeUsage)
    case error(AgentRuntimeFailure)
    case terminal(AgentRuntimeTerminal)

    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }
}

struct AgentRuntimeEventEnvelope: Equatable, Sendable {
    let sessionID: UUID
    let turnID: UUID
    let event: AgentRuntimeEvent
}

@MainActor
protocol AgentRuntimeAdapter: AnyObject {
    var descriptor: AgentRuntimeDescriptor { get }
    var state: AgentRuntimeState { get }

    func start(_ request: AgentRuntimeSessionRequest) throws
    func send(_ request: AgentRuntimeTurnRequest) throws -> AsyncStream<AgentRuntimeEventEnvelope>
    func cancel(sessionID: UUID)
    func resume(_ request: AgentRuntimeSessionRequest) throws
    func end(sessionID: UUID)
}

enum AgentRuntimeContractError: LocalizedError, Equatable, Sendable {
    case sessionMismatch
    case turnAlreadyRunning
    case sessionNotStarted
    case invalidCurrentMessage

    var errorDescription: String? {
        switch self {
        case .sessionMismatch: "The runtime event belongs to another chat session."
        case .turnAlreadyRunning: "The agent runtime is already handling a turn."
        case .sessionNotStarted: "The agent runtime session has not started."
        case .invalidCurrentMessage: "The current runtime message must be the final user message."
        }
    }
}

struct AgentRuntimeEventFence: Sendable {
    private(set) var sessionID: UUID?
    private(set) var turnID: UUID?
    private(set) var receivedTerminal = false

    mutating func begin(sessionID: UUID, turnID: UUID) {
        self.sessionID = sessionID
        self.turnID = turnID
        receivedTerminal = false
    }

    mutating func accepts(_ envelope: AgentRuntimeEventEnvelope) -> Bool {
        guard envelope.sessionID == sessionID,
              envelope.turnID == turnID,
              !receivedTerminal else { return false }
        if envelope.event.isTerminal {
            receivedTerminal = true
        }
        return true
    }
}

@MainActor
final class AgentRuntimeEventRelay {
    let stream: AsyncStream<AgentRuntimeEventEnvelope>

    private let sessionID: UUID
    private let turnID: UUID
    private let continuation: AsyncStream<AgentRuntimeEventEnvelope>.Continuation
    private(set) var terminal: AgentRuntimeTerminal?

    init(sessionID: UUID, turnID: UUID) {
        self.sessionID = sessionID
        self.turnID = turnID
        var continuation: AsyncStream<AgentRuntimeEventEnvelope>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func yield(_ event: AgentRuntimeEvent) {
        guard terminal == nil, !event.isTerminal else { return }
        continuation.yield(AgentRuntimeEventEnvelope(
            sessionID: sessionID,
            turnID: turnID,
            event: event
        ))
    }

    func finish(_ value: AgentRuntimeTerminal) {
        guard terminal == nil else { return }
        terminal = value
        continuation.yield(AgentRuntimeEventEnvelope(
            sessionID: sessionID,
            turnID: turnID,
            event: .terminal(value)
        ))
        continuation.finish()
    }
}
