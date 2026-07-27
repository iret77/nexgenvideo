import Foundation

enum AgentBackend: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case anthropicAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .anthropicAPI: return "Anthropic API"
        }
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
        if let raw = defaults.string(forKey: key), let backend = AgentBackend(rawValue: raw) {
            return backend
        }
        if defaults.object(forKey: legacyKey) != nil {
            return defaults.bool(forKey: legacyKey) ? .claudeCode : .anthropicAPI
        }
        return .anthropicAPI
    }

    static func set(_ backend: AgentBackend) {
        guard selected != backend else { return }
        let defaults = UserDefaults.standard
        defaults.set(backend.rawValue, forKey: key)
        defaults.set(backend == .claudeCode, forKey: legacyKey)
        NotificationCenter.default.post(name: .agentBackendChanged, object: backend)
    }
}
