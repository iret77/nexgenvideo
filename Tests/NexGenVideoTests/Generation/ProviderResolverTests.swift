import Testing

@testable import NexGenVideo

@Suite("ProviderResolver — LLM → NGV → Provider")
struct ProviderResolverTests {

    private func binding(_ p: GenerationProvider, _ t: ProviderTransport, _ ref: String,
                         _ billing: BillingMode) -> ProviderBinding {
        ProviderBinding(provider: p, transport: t, providerModelRef: ref, billing: billing)
    }

    @Test func cheapestActivatedBindingWins() {
        let cheap = binding(.fal, .api, "fal-ai/seedance", .perCall)
        let pricey = binding(.higgsfield, .api, "hf/seedance", .perCall)
        let activation = ProviderActivation(active: [
            .init(provider: .fal, transport: .api),
            .init(provider: .higgsfield, transport: .api),
        ])
        let cost: (ProviderBinding) -> Double = { $0.provider == .fal ? 1.0 : 2.0 }
        let picked = ProviderResolver.resolve(bindings: [pricey, cheap], activation: activation, effectiveCost: cost)
        #expect(picked == cheap)
    }

    @Test func inactiveProviderIsNeverChosenEvenIfCheaper() {
        // The globally-cheapest option is on a provider the user hasn't activated → skip it.
        let cheapButInactive = binding(.higgsfield, .api, "hf/seedance", .perCall)
        let activeDearer = binding(.fal, .api, "fal-ai/seedance", .perCall)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let cost: (ProviderBinding) -> Double = { $0.provider == .higgsfield ? 0.1 : 5.0 }
        let picked = ProviderResolver.resolve(bindings: [cheapButInactive, activeDearer], activation: activation, effectiveCost: cost)
        #expect(picked == activeDearer)
    }

    @Test func noActivatedProviderOffersItReturnsNil() {
        let onlyInactive = binding(.higgsfield, .mcp, "hf/seedance", .subscription)
        let activation = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        let picked = ProviderResolver.resolve(bindings: [onlyInactive], activation: activation, effectiveCost: { _ in 1 })
        #expect(picked == nil)
    }

    @Test func subscriptionTransportCanBeatPayPerCall() {
        // Billing-aware: the SAME model over an MCP subscription (flat, ~0 marginal) beats
        // the pay-per-call API when the caller's effectiveCost reflects the subscription.
        let apiCall = binding(.higgsfield, .api, "hf/model", .perCall)
        let mcpSub = binding(.higgsfield, .mcp, "hf/model", .subscription)
        let activation = ProviderActivation(active: [
            .init(provider: .higgsfield, transport: .api),
            .init(provider: .higgsfield, transport: .mcp),
        ])
        let cost: (ProviderBinding) -> Double = { $0.billing == .subscription ? 0.0 : 3.0 }
        let picked = ProviderResolver.resolve(bindings: [apiCall, mcpSub], activation: activation, effectiveCost: cost)
        #expect(picked == mcpSub)
    }

    @Test func perTransportActivationIsRespected() {
        // API key present, MCP not connected → only the API binding is eligible.
        let api = binding(.higgsfield, .api, "hf/model", .perCall)
        let mcp = binding(.higgsfield, .mcp, "hf/model", .subscription)
        let activation = ProviderActivation(active: [.init(provider: .higgsfield, transport: .api)])
        let picked = ProviderResolver.resolve(bindings: [mcp, api], activation: activation, effectiveCost: { $0.billing == .subscription ? 0 : 9 })
        #expect(picked == api)
    }
}
