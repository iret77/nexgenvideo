import Foundation
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

    @Test func apiOfferNeverInventsAnMCPBinding() {
        let bindings = ProviderManifest.bindings(
            from: [ProviderOffer(
                provider: .higgsfield,
                transport: .api,
                providerRef: "v1/images/generate"
            )],
            modelId: "lighting-anchor"
        )

        #expect(bindings.count == 1)
        #expect(bindings.first?.transport == .api)
        #expect(bindings.first?.providerRef == "v1/images/generate")
        #expect(bindings.first?.modelParam == nil)
    }

    @Test func directProviderIsCheaperThanFalMiddleman() {
        let direct = ProviderBinding(provider: .elevenlabs, transport: .api, kind: .generation, providerRef: "x", billing: .perCall)
        let hosted = ProviderBinding(provider: .fal, transport: .api, kind: .generation, providerRef: "x", billing: .perCall)
        #expect(ProviderManifest.effectiveCost(direct) < ProviderManifest.effectiveCost(hosted))
    }

    @Test func providerOfferPersistsProductionMetadata() throws {
        guard let entry = FalModelRegistry.entries.first(where: {
            $0.id == "fal-ai/veo3"
        }), case .video(let videoCapabilities) = entry.uiCapabilities else {
            Issue.record("Expected video capabilities")
            return
        }
        let inputPolicy = ProviderProductionInputPolicyV1(
            requiresSourceVideo: true,
            framesCountTowardImageReferenceLimit: false,
            framesCountTowardTotalReferenceLimit: true
        )
        let expected = ProviderOffer(
            provider: .fal,
            providerRef: "fal/exact-endpoint",
            productionQualityTargetIDs: ["high"],
            productionInputPolicy: inputPolicy,
            resolvedVideoCapabilities: ResolvedVideoOfferingCapabilitiesV1(
                videoCapabilities: videoCapabilities,
                inputPolicy: inputPolicy,
                supportsNativeAudio: true
            )
        )

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(ProviderOffer.self, from: data)

        #expect(decoded == expected)
        #expect(decoded.productionQualityTargetIDs == ["high"])
        #expect(decoded.productionInputPolicy?.requiresSourceVideo == true)
        #expect(
            decoded.productionInputPolicy?.framesCountTowardImageReferenceLimit == false
        )
        #expect(
            decoded.productionInputPolicy?.framesCountTowardTotalReferenceLimit == true
        )
        #expect(
            ProviderManifest.bindings(from: [decoded], modelId: "logical").first?
                .productionInputPolicy == expected.productionInputPolicy
        )
        #expect(
            ProviderManifest.bindings(from: [decoded], modelId: "logical").first?
                .resolvedVideoCapabilities == expected.resolvedVideoCapabilities
        )
    }

    @Test func everyBootstrapVideoOfferCarriesAnExactContract() {
        for entry in ModelCatalog.bootstrapEntries where entry.kind == .video {
            guard case .video(let videoCapabilities) = entry.uiCapabilities else {
                Issue.record("Expected video capabilities for \(entry.id)")
                continue
            }
            let offers = entry.offers ?? []
            #expect(!offers.isEmpty)
            for offer in offers {
                #expect(offer.productionInputPolicy != nil)
                #expect(offer.resolvedVideoCapabilities?.schemaVersion == 1)
                #expect(offer.resolvedVideoCapabilities?.contractViolation == nil)
                #expect(
                    offer.resolvedVideoCapabilities?.inputPolicy
                        == offer.productionInputPolicy
                )
                let supportsNativeAudio = offer.provider == .fal
                    && FalModelRegistry.model(for: entry.id)?.videoGeneratesAudio == true
                #expect(offer.resolvedVideoCapabilities == offer.productionInputPolicy.map {
                    ResolvedVideoOfferingCapabilitiesV1(
                        videoCapabilities: videoCapabilities,
                        inputPolicy: $0,
                        supportsNativeAudio: supportsNativeAudio
                    )
                })
            }
        }
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
