import Foundation

enum AgentBackend: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case anthropicAPI
    case codexAppServer

    static let selectableCases: [AgentBackend] = [.claudeCode, .anthropicAPI]

    var id: String { rawValue }

    var runtimeID: AgentBackendID {
        switch self {
        case .claudeCode: .claudeCode
        case .anthropicAPI: .anthropicAPI
        case .codexAppServer: .codexAppServer
        }
    }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .anthropicAPI: return "Anthropic API"
        case .codexAppServer: return "Codex"
        }
    }

    var runtimeIdentity: AgentRuntimeIdentity {
        AgentRuntimeIdentity(backendID: runtimeID, displayName: displayName)
    }

    var authentication: AgentRuntimeAuthentication {
        switch self {
        case .claudeCode:
            .externalSubscription(command: "claude")
        case .anthropicAPI:
            .apiKey(service: "Anthropic")
        case .codexAppServer:
            .isolatedExternalAccount(command: "codex app-server")
        }
    }

    func runtimeDescriptor(
        toolNames: Set<String>,
        providerExtensions: Set<String> = []
    ) -> AgentRuntimeDescriptor {
        let activeProviderExtensions = self == .claudeCode ? providerExtensions : []
        var operations: Set<AgentRuntimeOperation> = [
            .streamText,
            .submitImages,
            .hiddenMessages,
            .localizedInstructions,
            .phaseInstructions,
        ]
        if !toolNames.isEmpty {
            operations.insert(.executeHostTools)
        }
        if toolNames.contains(ToolName.showDialog.rawValue) {
            operations.insert(.structuredDialogs)
        }
        let approvalTools: Set<String> = [
            ToolName.approveGate.rawValue,
            ToolName.setGateState.rawValue,
            ToolName.generateVideo.rawValue,
            ToolName.generateImage.rawValue,
            ToolName.generateAudio.rawValue,
            ToolName.upscaleMedia.rawValue,
        ]
        if !toolNames.isDisjoint(with: approvalTools) {
            operations.insert(.approvalSuspension)
        }
        let transport: AgentToolExecutionTransport
        switch self {
        case .claudeCode:
            operations.formUnion([.resumeNativeSession, .reportCostUsage, .readProjectFiles])
            if !activeProviderExtensions.isEmpty {
                operations.insert(.externalClaudeCodePlugins)
            }
            transport = .providerManagedMCP
        case .anthropicAPI:
            operations.formUnion([.resumeFromTranscript, .reportTokenUsage])
            transport = .hostRoundTrip
        case .codexAppServer:
            operations.insert(.reportTokenUsage)
            transport = .hostRoundTrip
        }
        return AgentRuntimeDescriptor(
            identity: runtimeIdentity,
            authentication: authentication,
            capabilities: .init(
                operations: operations,
                toolNames: toolNames,
                providerExtensions: activeProviderExtensions
            ),
            toolExecutionTransport: transport
        )
    }
}

extension Notification.Name {
    static let agentBackendChanged = Notification.Name("agentBackendChanged")
    static let claudeCodeStatusChanged = Notification.Name("claudeCodeStatusChanged")
}

enum AgentBackendPreference {
    static let key = "agentBackend"
    static let legacyKey = "useClaudeCodeRuntime"

    static var selected: AgentBackend {
        selected(in: .standard)
    }

    static func selected(in defaults: UserDefaults) -> AgentBackend {
        if let raw = defaults.string(forKey: key),
           let backend = AgentBackend(rawValue: raw),
           AgentBackend.selectableCases.contains(backend) {
            return backend
        }
        if defaults.object(forKey: legacyKey) != nil {
            return defaults.bool(forKey: legacyKey) ? .claudeCode : .anthropicAPI
        }
        return .anthropicAPI
    }

    static func set(_ backend: AgentBackend) {
        guard AgentBackend.selectableCases.contains(backend), selected != backend else { return }
        let defaults = UserDefaults.standard
        defaults.set(backend.rawValue, forKey: key)
        defaults.set(backend == .claudeCode, forKey: legacyKey)
        NotificationCenter.default.post(name: .agentBackendChanged, object: backend)
    }
}
