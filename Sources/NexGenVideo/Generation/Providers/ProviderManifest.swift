import Foundation

/// The concrete manifest feeding the resolver: given a model id, the ways the CURRENT
/// catalog can produce it, as `ProviderBinding`s. Pure mapping, no I/O.
///
/// This is the seam the remote model-card catalog + MCP transports grow into. Today every
/// model is one `.api` binding, and the one real multi-source case — the ElevenLabs family
/// (direct-to-ElevenLabs vs fal-hosted) — is two bindings resolved by activation, replacing
/// the hardcoded `if elevenlabs.hasKey` in the old prefix ladder.
enum ProviderManifest {
    /// All bindings for a model, built from the catalog's DECLARED provider offers (data, not
    /// id-prefix inference): each offer becomes a binding, and an `.api` offer whose provider also
    /// has a configured MCP additionally gets an `.mcp` (subscription) binding. The resolver then
    /// picks the cheapest activated one. When the catalog hasn't declared offers for a model
    /// (legacy registry entry, or catalog not yet loaded) `defaultOffers` bootstraps them.
    @MainActor
    static func bindings(forModelId id: String) -> [ProviderBinding] {
        let offers = ModelCatalog.shared.offersById[id] ?? defaultOffers(forModelId: id)
        var out: [ProviderBinding] = []
        for offer in offers {
            let ref = offer.providerRef ?? id
            out.append(ProviderBinding(
                provider: offer.provider, transport: offer.transport, kind: .generation,
                providerRef: ref, billing: offer.transport == .mcp ? .subscription : .perCall,
                costPerCall: offer.costPerCall, modelParam: offer.modelParam))
            if offer.transport == .api, ProviderMCP.hasConfig(offer.provider) {
                out.append(ProviderBinding(
                    provider: offer.provider, transport: .mcp, kind: .generation,
                    providerRef: ref, billing: .subscription))
            }
        }
        return out
    }

    /// Bootstrap offers for a model the catalog hasn't declared — the provider from registry
    /// membership; the ElevenLabs family is direct-to-ElevenLabs + fal-hosted. The hosted catalog's
    /// declared `offers` override this (that's the path to provider-neutral, multi-provider models).
    static func defaultOffers(forModelId id: String) -> [ProviderOffer] {
        if id.hasPrefix("fal-ai/elevenlabs") {
            return [ProviderOffer(provider: .elevenlabs, providerRef: id),
                    ProviderOffer(provider: .fal, providerRef: id)]
        }
        return [ProviderOffer(provider: nominalProvider(forModelId: id), providerRef: id)]
    }

    /// The single provider a non-multi-source model belongs to (registry membership) — the
    /// bootstrap default when the catalog hasn't declared offers.
    static func nominalProvider(forModelId id: String) -> GenerationProvider {
        if MarbleModelRegistry.isMarbleModel(id) { return .marble }
        if RunwayModelRegistry.isRunwayModel(id) { return .runway }
        // #212: a direct-provider-only model whose provider isn't activated resolves to no binding, and
        // dispatch falls back here. Without these, an `openai/…` id would land on fal and the user would
        // be told to add a *fal* key for an OpenAI model. Models that SHARE a fal id (Imagen) are
        // deliberately absent — falling back to fal is right for them.
        if id.hasPrefix(GoogleModelRegistry.idPrefix) { return .google }
        if id.hasPrefix(OpenAIModelRegistry.idPrefix) { return .openai }
        // Higgsfield models arrive via runtime MCP discovery (raw ids, always carrying `.mcp` offers),
        // so they never fall through to this bootstrap default — no `higgsfield/` prefix branch needed.
        return .fal
    }

    /// Activated providers reachable over MCP, cheapest first — the candidates for a workflow
    /// tool-call (M4). WHICH one actually exposes the named tool is discovered at call time
    /// (tools/list), so this is only the try-order; discovery-driven, no per-provider tool table.
    @MainActor
    static func toolProvidersCheapestFirst() -> [GenerationProvider] {
        GenerationProvider.allCases
            .filter { ProviderMCP.hasConfig($0) }
            .map { ProviderBinding(provider: $0, transport: .mcp, kind: .tool, providerRef: "", billing: .subscription) }
            .sorted { effectiveCost($0) < effectiveCost($1) }
            .map(\.provider)
    }

    /// Billing-aware cost of THIS call for a binding. Placeholder until the catalog's
    /// per-(model, provider, transport) price feeds in: a subscription MCP is cheaper per call
    /// than a pay-per-call API, and a provider's own endpoint beats the fal-hosted middleman
    /// (ElevenLabs direct over fal). Real prices replace this.
    static func effectiveCost(_ b: ProviderBinding) -> Double {
        if let declared = b.costPerCall { return declared }
        var cost = b.billing == .subscription ? 0.0 : 1.0
        if b.provider == .fal { cost += 0.5 }
        return cost
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
