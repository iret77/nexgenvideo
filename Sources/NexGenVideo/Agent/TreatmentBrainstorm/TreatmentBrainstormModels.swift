import Foundation

extension Notification.Name {
    static let treatmentBrainstormSettingsChanged = Notification.Name("treatmentBrainstormSettingsChanged")
    static let treatmentBrainstormPreferencesChanged = Notification.Name("treatmentBrainstormPreferencesChanged")
}

enum TreatmentBrainstormProvider: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case anthropic
    case openai
    case google

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .google: "Google AI"
        }
    }

    var hasCredential: Bool {
        switch self {
        case .anthropic: AnthropicKeychain.load() != nil
        case .openai: OpenAIKeychain.load() != nil
        case .google: ProviderKeychain.load(.google) != nil
        }
    }

    var apiKey: String? {
        switch self {
        case .anthropic: AnthropicKeychain.load()
        case .openai: OpenAIKeychain.load()
        case .google: ProviderKeychain.load(.google)
        }
    }
}

enum OpenAIKeychain {
    private static let account = "openai-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .treatmentBrainstormSettingsChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .treatmentBrainstormSettingsChanged, object: nil)
    }
}

struct TreatmentBrainstormModel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let displayName: String
    let provider: TreatmentBrainstormProvider
    let supportsStructuredOutput: Bool
    let costDisclosure: String

    var preferenceID: String { "\(provider.rawValue):\(id)" }
}

enum TreatmentBrainstormModelCatalog {
    static let all: [TreatmentBrainstormModel] = [
        .init(
            id: "claude-sonnet-5",
            displayName: "Claude Sonnet 5",
            provider: .anthropic,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "claude-opus-5",
            displayName: "Claude Opus 5",
            provider: .anthropic,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "claude-haiku-4-5-20251001",
            displayName: "Claude Haiku 4.5",
            provider: .anthropic,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            provider: .openai,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            provider: .openai,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            provider: .openai,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "gemini-3.8-flash",
            displayName: "Gemini 3.8 Flash",
            provider: .google,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
        .init(
            id: "gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            provider: .google,
            supportsStructuredOutput: true,
            costDisclosure: "Provider-billed by input and output tokens"
        ),
    ]

    static func definition(provider: TreatmentBrainstormProvider, modelID: String) -> TreatmentBrainstormModel? {
        all.first { $0.provider == provider && $0.id == modelID }
    }
}

enum TreatmentBrainstormPreferences {
    static let defaultsKey = "treatmentBrainstorm.enabledModels.v1"

    static func enabledRouteIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
            .intersection(TreatmentBrainstormModelCatalog.all.map(\.preferenceID))
    }

    static func isEnabled(_ model: TreatmentBrainstormModel, defaults: UserDefaults = .standard) -> Bool {
        enabledRouteIDs(defaults: defaults).contains(model.preferenceID)
    }

    static func setEnabled(
        _ enabled: Bool,
        model: TreatmentBrainstormModel,
        defaults: UserDefaults = .standard
    ) {
        var ids = enabledRouteIDs(defaults: defaults)
        if enabled { ids.insert(model.preferenceID) } else { ids.remove(model.preferenceID) }
        defaults.set(ids.sorted(), forKey: defaultsKey)
        NotificationCenter.default.post(name: .treatmentBrainstormPreferencesChanged, object: nil)
    }
}
