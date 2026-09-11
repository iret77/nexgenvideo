import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Native model support without capability research")
struct CatalogNativeCapabilitiesTests {
    @Test func qwenShipsItsOutputCountAndAspectRatios() throws {
        let entry = try #require(FalModelRegistry.model(for: "fal-ai/qwen-image")?.entry)
        let capability = try #require(ModelCatalog.offeringCapabilities(for: entry, resolver: resolver()).first)
        let fields = capability.effective.fields
        #expect(fields.integers[CapabilityFieldIDV1.imageOutputsPerRequest]?.value == 4)
        #expect(fields.integers[CapabilityFieldIDV1.imageReferences]?.value == 0)
        #expect(fields.strings[CapabilityFieldIDV1.aspectRatios]?.value.contains("16:9") == true)
        #expect(fields.integers[CapabilityFieldIDV1.imageVisibleCharacters]?.origin.kind == .defensive)
    }

    @Test func elevenLabsMusicShipsItsDurationForBothProviders() throws {
        let entry = try #require(FalModelRegistry.model(for: "fal-ai/elevenlabs/music")?.entry)
        let capabilities = try ModelCatalog.offeringCapabilities(for: entry, resolver: resolver())
        #expect(Set(capabilities.map { $0.offering.providerID }) == ["fal", "elevenlabs"])
        for capability in capabilities {
            #expect(capability.effective.fields.decimals[CapabilityFieldIDV1.audioDurationMinimum]?.value == 3)
            #expect(capability.effective.fields.decimals[CapabilityFieldIDV1.audioDurationMaximum]?.value == 600)
            #expect(capability.effective.fields.booleans[CapabilityFieldIDV1.audioLyrics]?.value == false)
        }
    }

    @Test func providerSpecificLimitsDoNotBorrowAnotherProvidersCapacity() throws {
        let entry = try #require(RunwayModelRegistry.entries.first { $0.id == "runway/gemini_2.5_flash" })
        let capability = try #require(ModelCatalog.offeringCapabilities(for: entry, resolver: resolver()).first)
        #expect(capability.effective.fields.integers[CapabilityFieldIDV1.imageReferences]?.value == 3)
        #expect(capability.effective.fields.integers[CapabilityFieldIDV1.imageOutputsPerRequest]?.value == 1)
        #expect(capability.intrinsic == (try resolver().resolve(.init(modality: .image, catalogModelID: entry.id))))
    }

    @Test func discoveredAliasesUseTheSameNativeImageAdapter() throws {
        let entry = try #require(FalModelRegistry.discoveredEntries(availableModelIds: ["openai/gpt-image-2/edit"]).first)
        let capability = try #require(ModelCatalog.offeringCapabilities(for: entry, resolver: resolver()).first)
        #expect(capability.effective.fields.integers[CapabilityFieldIDV1.imageReferences]?.origin.kind == .endpointOverlay)
        #expect(capability.effective.fields.integers[CapabilityFieldIDV1.imageReferences]?.origin.endpointID == "openai/gpt-image-2/edit")
    }

    @Test func nativeDefaultsCannotExpandUnrecognizedOrMCPBindings() throws {
        let entry = try #require(FalModelRegistry.model(for: "fal-ai/qwen-image")?.entry)
        for offer in [ProviderOffer(provider: .fal, providerRef: "another-endpoint"),
                      ProviderOffer(provider: .fal, transport: .mcp, providerRef: entry.id)] {
            let offering = CatalogOfferingIdentity.make(offer: offer, modelID: entry.id, modality: .image)
            let original = try resolver().resolveOffering(offering, lookup: .init(modality: .image, catalogModelID: entry.id))
            #expect(CatalogNativeCapabilities.applying(to: original, offer: offer) == original)
        }
    }

    @MainActor
    @Test func aFreshCatalogSupportsEveryShippedEntryWithoutStartingResearch() throws {
        let catalog = ModelCatalog()
        let entries = ModelCatalog.bootstrapEntries
        catalog.load(entries: entries)
        #expect(catalog.lastError == nil)
        #expect(Set(catalog.byId.keys) == Set(entries.map(\.id)))
        #expect(catalog.offeringCapabilitiesByModelID == catalog.curatedOfferingCapabilitiesByModelID)
    }

    private func resolver() throws -> ModelCapabilityResolver {
        try ModelCapabilityResolver(knowledgeBase: BundledModelCapabilityCorpus.load().productionKnowledgeBase())
    }
}
