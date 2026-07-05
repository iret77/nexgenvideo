import Foundation

extension Notification.Name {
    static let providerKeysChanged = Notification.Name("providerKeysChanged")
}

enum GenerationProvider: String, CaseIterable, Identifiable {
    case fal
    case runway
    case higgsfield
    case elevenlabs
    case marble

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fal: return "fal.ai"
        case .runway: return "Runway"
        case .higgsfield: return "Higgsfield"
        case .elevenlabs: return "ElevenLabs"
        case .marble: return "Marble"
        }
    }

    var modalities: String {
        switch self {
        case .fal: return "Video · Image · Audio"
        case .runway: return "Video"
        case .higgsfield: return "Video \u{00B7} key format: KEY_ID:KEY_SECRET"
        case .elevenlabs: return "Voice · SFX · Music"
        case .marble: return "3D World · Panorama"
        }
    }

    var keysURL: URL {
        switch self {
        case .fal: return URL(string: "https://fal.ai/dashboard/keys")!
        case .runway: return URL(string: "https://dev.runwayml.com")!
        case .higgsfield: return URL(string: "https://cloud.higgsfield.ai")!
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .marble: return URL(string: "https://platform.worldlabs.ai/")!
        }
    }

    var keychainAccount: String { "provider.\(rawValue).api-key" }
}

enum ProviderKeychain {
    static func save(_ key: String, for provider: GenerationProvider) {
        KeychainStore.save(key, account: provider.keychainAccount)
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }

    static func load(_ provider: GenerationProvider) -> String? {
        KeychainStore.load(account: provider.keychainAccount)
    }

    static func delete(_ provider: GenerationProvider) {
        KeychainStore.delete(account: provider.keychainAccount)
        NotificationCenter.default.post(name: .providerKeysChanged, object: nil)
    }
}

extension GenerationProvider {
    /// The provider that actually services a generation model id. Marble models go to Marble;
    /// ElevenLabs-family models go DIRECTLY to ElevenLabs when the user's key is present (their
    /// account, no fal middleman) and fall back to fal's hosted endpoints otherwise; the rest is fal.
    static func servicing(modelId: String) -> GenerationProvider {
        if MarbleModelRegistry.isMarbleModel(modelId) { return .marble }
        if RunwayModelRegistry.isRunwayModel(modelId) { return .runway }
        if HiggsfieldModelRegistry.isHiggsfieldModel(modelId) { return .higgsfield }
        if modelId.hasPrefix("fal-ai/elevenlabs"), GenerationProvider.elevenlabs.hasKey {
            return .elevenlabs
        }
        return .fal
    }
    /// Whether a BYO API key is configured for this provider. A model whose provider has no key
    /// is accepted by the generate tools but fails at request time — gate on this first.
    var hasKey: Bool { ProviderKeychain.load(self) != nil }
}
