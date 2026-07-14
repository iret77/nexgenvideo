import Testing

@testable import NexGenVideo

@Suite("ProviderManifest — model id → bindings")
@MainActor
struct ProviderManifestTests {

    // Higgsfield is intentionally absent: its DoP direct registry was retired (#163). Higgsfield models
    // now arrive via runtime MCP discovery with raw ids carrying `.mcp` offers (see MCPModelDiscoveryTests),
    // never as a static `higgsfield/`-prefixed `.api` binding.
    @Test func singleSourceModelsMapToOneApiBinding() {
        for (id, provider) in [
            ("marble/marble-1.1", GenerationProvider.marble),
            ("runway/gen4.5", .runway),
            ("fal-ai/flux-pro/v1.1", .fal),
        ] {
            let bindings = ProviderManifest.bindings(forModelId: id)
            #expect(bindings.count == 1)
            #expect(bindings.first?.provider == provider)
            #expect(bindings.first?.transport == .api)
            #expect(bindings.first?.kind == .generation)
            #expect(bindings.first?.providerRef == id)
        }
    }

    @Test func elevenlabsFamilyIsTwoBindingsDirectAndFalHosted() {
        let id = "fal-ai/elevenlabs/tts/multilingual-v2"
        let bindings = ProviderManifest.bindings(forModelId: id)
        #expect(bindings.count == 2)
        #expect(bindings.contains { $0.provider == .elevenlabs && $0.transport == .api })
        #expect(bindings.contains { $0.provider == .fal && $0.transport == .api })
        #expect(bindings.allSatisfy { $0.kind == .generation })
    }

    @Test func directProviderIsCheaperThanFalMiddleman() {
        let direct = ProviderBinding(provider: .elevenlabs, transport: .api, kind: .generation, providerRef: "x", billing: .perCall)
        let hosted = ProviderBinding(provider: .fal, transport: .api, kind: .generation, providerRef: "x", billing: .perCall)
        #expect(ProviderManifest.effectiveCost(direct) < ProviderManifest.effectiveCost(hosted))
    }

    @Test func elevenlabsResolvesDirectWhenActivatedElseFalHosted() {
        let id = "fal-ai/elevenlabs/tts/multilingual-v2"
        let bindings = ProviderManifest.bindings(forModelId: id)
        // both keys → direct ElevenLabs (no fal middleman)
        let both = ProviderActivation(active: [
            .init(provider: .elevenlabs, transport: .api), .init(provider: .fal, transport: .api),
        ])
        #expect(ProviderResolver.resolve(bindings: bindings, activation: both, effectiveCost: ProviderManifest.effectiveCost)?.provider == .elevenlabs)
        // only fal key → fal-hosted fallback
        let falOnly = ProviderActivation(active: [.init(provider: .fal, transport: .api)])
        #expect(ProviderResolver.resolve(bindings: bindings, activation: falOnly, effectiveCost: ProviderManifest.effectiveCost)?.provider == .fal)
    }
}
