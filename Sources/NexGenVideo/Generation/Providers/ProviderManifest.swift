import Foundation

/// The concrete manifest feeding the resolver: given a model id, the ways the CURRENT
/// catalog can produce it, as `ProviderBinding`s. Pure mapping, no I/O.
///
/// This is the seam the remote model-card catalog + MCP transports grow into. Today every
/// model is one `.api` binding, and the one real multi-source case — the ElevenLabs family
/// (direct-to-ElevenLabs vs fal-hosted) — is two bindings resolved by activation, replacing
/// the hardcoded `if elevenlabs.hasKey` in the old prefix ladder.
enum ProviderManifest {
    /// The candidate providers that can service a model — the ElevenLabs family has two (direct +
    /// fal-hosted), everything else one.
    static func candidateProviders(forModelId id: String) -> [GenerationProvider] {
        id.hasPrefix("fal-ai/elevenlabs") ? [.elevenlabs, .fal] : [nominalProvider(forModelId: id)]
    }

    /// All bindings for a model: each candidate provider over `.api` (its key) and, when the user has
    /// configured that provider's MCP, ALSO over `.mcp` (subscription). The resolver then picks the
    /// cheapest activated one. The `.mcp` binding's `providerRef` stays the logical model id here; the
    /// dispatch layer maps it to the provider's discovered MCP tool (`tools/list`) at call time.
    static func bindings(forModelId id: String) -> [ProviderBinding] {
        candidateProviders(forModelId: id).flatMap { provider -> [ProviderBinding] in
            var out = [ProviderBinding(provider: provider, transport: .api, kind: .generation,
                                       providerRef: id, billing: .perCall)]
            if ProviderMCP.hasConfig(provider) {
                out.append(ProviderBinding(provider: provider, transport: .mcp, kind: .generation,
                                           providerRef: id, billing: .subscription))
            }
            return out
        }
    }

    /// The single provider a non-multi-source model belongs to (registry membership) — the
    /// hot path used for display/availability, no activation lookup needed.
    static func nominalProvider(forModelId id: String) -> GenerationProvider {
        if MarbleModelRegistry.isMarbleModel(id) { return .marble }
        if RunwayModelRegistry.isRunwayModel(id) { return .runway }
        if HiggsfieldModelRegistry.isHiggsfieldModel(id) { return .higgsfield }
        return .fal
    }

    /// Billing-aware cost of THIS call for a binding. Placeholder until the catalog's
    /// per-(model, provider, transport) price feeds in: prefers a provider's own direct
    /// endpoint over the fal-hosted fallback (ElevenLabs direct beats the fal middleman).
    static func effectiveCost(_ b: ProviderBinding) -> Double {
        b.provider == .fal ? 1.0 : 0.0
    }
}

extension ProviderActivation {
    /// Activation from real state, per transport: an API key in the Keychain activates `.api`; a
    /// configured MCP endpoint activates `.mcp`. A provider may have both — then the resolver weighs
    /// them by billing (pay-per-call API vs subscription MCP).
    static func current() -> ProviderActivation {
        var keys: Set<Key> = []
        for provider in GenerationProvider.allCases {
            if provider.hasKey { keys.insert(Key(provider: provider, transport: .api)) }
            if ProviderMCP.hasConfig(provider) { keys.insert(Key(provider: provider, transport: .mcp)) }
        }
        return ProviderActivation(active: keys)
    }
}
