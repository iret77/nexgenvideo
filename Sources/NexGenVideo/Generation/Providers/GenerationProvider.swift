import Foundation

extension Notification.Name {
    static let providerKeysChanged = Notification.Name("providerKeysChanged")
}

enum GenerationProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case fal
    case runway
    case higgsfield
    case elevenlabs
    case marble
    case openart
    case ace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fal: return "fal.ai"
        case .runway: return "Runway"
        case .higgsfield: return "Higgsfield"
        case .elevenlabs: return "ElevenLabs"
        case .marble: return "Marble"
        case .openart: return "OpenArt"
        case .ace: return "ACE Studio"
        }
    }

    var modalities: String {
        switch self {
        case .fal: return "Video · Image · Audio"
        case .runway: return "Video"
        case .higgsfield: return "Video \u{00B7} Image \u{00B7} 30+ models \u{00B7} sign in (MCP)"
        case .elevenlabs: return "Voice · SFX · Music"
        case .marble: return "3D World · Panorama"
        case .openart: return "Image · Video \u{00B7} via MCP"
        case .ace: return "Voice · Singing \u{00B7} via MCP"
        }
    }

    var keysURL: URL {
        switch self {
        case .fal: return URL(string: "https://fal.ai/dashboard/keys")!
        case .runway: return URL(string: "https://dev.runwayml.com")!
        case .higgsfield: return URL(string: "https://higgsfield.ai/mcp")!
        case .elevenlabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .marble: return URL(string: "https://platform.worldlabs.ai/")!
        case .openart: return URL(string: "https://openart.ai")!
        case .ace: return URL(string: "https://acestudio.ai")!
        }
    }

    /// Whether NGV has a direct REST client for this provider's own API key. When false the provider
    /// is reached ONLY over MCP (no API-key field is shown — that would be a dead field). OpenArt and
    /// ACE route through NGV as an MCP client, on the user's subscription.
    var supportsDirectAPI: Bool {
        switch self {
        case .fal, .runway, .elevenlabs, .marble: return true
        // Higgsfield issues no API keys ("No API keys to manage or configure" — higgsfield.ai/mcp);
        // it, OpenArt and ACE are reached ONLY over MCP. No API-key field (that would be dead).
        case .higgsfield, .openart, .ace: return false
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
    /// The provider that actually services a generation model id — resolved by NGV over the
    /// manifest's bindings and the user's activation (LLM → NGV → Provider). Single-source
    /// models (marble/runway/higgsfield/fal) return their one provider directly. The one
    /// multi-source case, the ElevenLabs family, is now general resolution: direct-to-ElevenLabs
    /// when its key is present (their account, no fal middleman), fal-hosted otherwise.
    @MainActor
    static func servicing(modelId: String) -> GenerationProvider {
        let bindings = ProviderManifest.bindings(forModelId: modelId)
        if bindings.count == 1 { return bindings[0].provider }
        let picked = ProviderResolver.resolve(
            bindings: bindings, activation: .current(), effectiveCost: ProviderManifest.effectiveCost)
        return picked?.provider ?? bindings.last?.provider ?? .fal
    }
    /// Whether a BYO API key is configured for this provider. A model whose provider has no key
    /// is accepted by the generate tools but fails at request time — gate on this first.
    var hasKey: Bool { ProviderKeychain.load(self) != nil }

    /// Whether the user can actually run this model NOW — i.e. SOME activated provider+transport
    /// services it (an API key, a configured MCP, or the ElevenLabs fal-hosted fallback). This is
    /// the availability signal for the catalog/UI. `servicing` only says WHICH provider wins; it can
    /// resolve to a keyless provider (e.g. MCP), so `servicing(_).hasKey` is NOT a valid availability
    /// check — a model runnable via another activated binding would be wrongly hidden.
    @MainActor
    static func canRun(modelId: String) -> Bool {
        ProviderResolver.resolve(
            bindings: ProviderManifest.bindings(forModelId: modelId),
            activation: .current(),
            effectiveCost: ProviderManifest.effectiveCost) != nil
    }
}
