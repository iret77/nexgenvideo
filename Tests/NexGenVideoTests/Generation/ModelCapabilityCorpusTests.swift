import NexGenEngine
import Testing

@testable import NexGenVideo

@Suite("Bundled model capability corpus")
struct ModelCapabilityCorpusTests {
    @Test("the versioned corpus is bundled, complete, and production-approved")
    func bundledCorpusContract() throws {
        let document = try BundledModelCapabilityCorpus.load()

        #expect(document.schema == "model-capability-corpus/v1")
        #expect(document.observedAt == "2026-08-31")
        #expect(document.staleAfterDays == 120)
        #expect(document.inventory.count == 87)
        #expect(document.inventory.filter { !$0.fixture }.count == 85)
        #expect(document.knowledgeBase.profiles.count == 59)
        #expect(document.knowledgeBase.aliases.count == 191)
        #expect(document.defensiveDefaults.ownerConfirmation == "confirmed")
        #expect(document.defensiveDefaults.table.characterAndPrimaryReferenceCounts == 1)
        #expect(document.defensiveDefaults.table.imageOutputsPerRequest == 1)
        #expect(document.defensiveDefaults.table.otherIntegerCounts == 0)
        #expect(document.defensiveDefaults.table.durationMinimumSeconds == 0)
        #expect(document.defensiveDefaults.table.durationMaximumSeconds == 30)
        #expect(document.defensiveDefaults.table.booleans == false)
        #expect(document.defensiveDefaults.table.sets.isEmpty)
        #expect(try document.productionKnowledgeBase() == document.knowledgeBase)
        #expect(CatalogCapabilityRuntime.resolver != nil)
        #expect(CatalogCapabilityRuntime.loadError == nil)
    }

    @Test("Seedance 2.5 keeps hard API limits separate from reliable capacity")
    func seedance25ReferenceCapacity() throws {
        let resolver = try resolver()
        let profile = try resolver.resolve(
            CapabilityLookupV1(
                modality: .video,
                catalogModelID: "fal::bytedance/seedance-2.5/reference-to-video"
            )
        )

        #expect(profile.resolvedIdentity?.familyID == "seedance")
        #expect(profile.resolvedIdentity?.variantID == "reference-to-video")
        #expect(profile.resolvedIdentity?.versionID == "2.5")
        #expect(profile.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 30)
        #expect(profile.fields.integers[CapabilityFieldIDV1.referenceVideos]?.value == 10)
        #expect(profile.fields.integers[CapabilityFieldIDV1.referenceAudios]?.value == 10)
        #expect(profile.fields.integers[CapabilityFieldIDV1.totalReferences]?.value == 50)
        #expect(
            profile.fields.integers[CapabilityFieldIDV1.referenceImages]?.semantics
                == .hardAPILimit
        )
        #expect(profile.fields.integers[CapabilityFieldIDV1.visibleCharacters]?.value == 5)
        #expect(
            profile.fields.integers[CapabilityFieldIDV1.visibleCharacters]?.semantics
                == .reliableCapacity
        )
        #expect(
            profile.fields.strings[CapabilityFieldIDV1.resolutions]?.value
                == ["480p", "720p"]
        )
    }

    @Test("MiniMax H3 preserves published reference capacity and leaves figures unknown")
    func minimaxH3ReferenceCapacity() throws {
        let resolver = try resolver()
        let profile = try resolver.resolve(
            CapabilityLookupV1(
                modality: .video,
                catalogModelID: "fal::minimax/h3/reference-to-video"
            )
        )

        #expect(profile.resolvedIdentity?.familyID == "minimax-h3")
        #expect(profile.resolvedIdentity?.variantID == "ref2va")
        #expect(profile.resolvedIdentity?.versionID == "3")
        #expect(profile.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 9)
        #expect(profile.fields.integers[CapabilityFieldIDV1.referenceVideos]?.value == 3)
        #expect(profile.fields.integers[CapabilityFieldIDV1.referenceAudios]?.value == 3)
        #expect(profile.fields.integers[CapabilityFieldIDV1.totalReferences]?.value == 12)
        #expect(
            profile.fields.integers[CapabilityFieldIDV1.referenceImages]?.origin.kind == .exact
        )
        #expect(profile.fields.integers[CapabilityFieldIDV1.visibleCharacters]?.value == 1)
        #expect(
            profile.fields.integers[CapabilityFieldIDV1.visibleCharacters]?.origin.kind
                == .defensive
        )
        #expect(profile.researchNeeded)
    }

    @Test("provider-qualified aliases resolve to one intrinsic image profile")
    func providerAliasesShareIntrinsicTruth() throws {
        let resolver = try resolver()
        let fal = try resolver.resolve(
            CapabilityLookupV1(
                modality: .image,
                catalogModelID: "fal::fal-ai/nano-banana-pro"
            )
        )
        let runway = try resolver.resolve(
            CapabilityLookupV1(
                modality: .image,
                catalogModelID: "runway::gemini_image3_pro"
            )
        )
        let google = try resolver.resolve(
            CapabilityLookupV1(
                modality: .image,
                catalogModelID: "google::gemini-3-pro-image"
            )
        )

        #expect(fal.resolvedIdentity == runway.resolvedIdentity)
        #expect(fal.resolvedIdentity == google.resolvedIdentity)
        #expect(fal.fields == runway.fields)
        #expect(fal.fields == google.fields)
        #expect(fal.fields.integers[CapabilityFieldIDV1.imageReferences]?.value == 14)
        #expect(fal.fields.integers[CapabilityFieldIDV1.imageVisibleCharacters]?.value == 5)
    }

    @Test("future and unknown identities resolve only through explicit conservative paths")
    func futureAndUnknownResolution() throws {
        let resolver = try resolver()
        let future = try resolver.resolve(
            CapabilityLookupV1(
                familyID: "seedance",
                variantID: "reference-to-video",
                versionID: "3.0",
                modality: .video,
                catalogModelID: "fixture/seedance-3.0/reference-to-video"
            )
        )
        let unknown = try resolver.resolve(
            CapabilityLookupV1(
                modality: .video,
                catalogModelID: "fixture/hupfntrupfn"
            )
        )

        #expect(future.requestedIdentity?.versionID == "3.0")
        #expect(future.resolvedIdentity?.versionID == "2.5")
        #expect(
            future.fields.integers[CapabilityFieldIDV1.referenceImages]?.origin.kind
                == .inherited
        )
        #expect(future.researchNeeded)
        #expect(unknown.resolvedIdentity == nil)
        #expect(unknown.defensiveProfileID == "defensive.video.owner-confirmed-v1")
        #expect(unknown.fields.integers[CapabilityFieldIDV1.referenceImages]?.value == 1)
        #expect(unknown.researchNeeded)
    }

    @Test("stale and conflicting inventory evidence remains explicit")
    func staleAndConflictEvidence() throws {
        let document = try BundledModelCapabilityCorpus.load()
        let stale = document.inventory.filter { $0.availability == "stale" }
        #expect(stale.count == 3)
        #expect(stale.contains { $0.providerModelID == "fal-ai/imagen4" })
        #expect(stale.contains { $0.providerModelID == "gemini-3-pro-image-preview" })
        #expect(stale.contains { $0.providerModelID == "gemini-3.1-flash-image-preview" })

        let resolver = try ModelCapabilityResolver(knowledgeBase: document.knowledgeBase)
        let h3 = try resolver.resolve(
            CapabilityLookupV1(
                modality: .video,
                catalogModelID: "fal::minimax/h3/reference-to-video"
            )
        )
        #expect(
            h3.fields.decimals[CapabilityFieldIDV1.durationMinimum]?.evidence
                .contains { $0.conflict != nil } == true
        )
        #expect(
            h3.fields.strings[CapabilityFieldIDV1.resolutions]?.evidence
                .contains { $0.conflict != nil } == true
        )
    }

    private func resolver() throws -> ModelCapabilityResolver {
        let document = try BundledModelCapabilityCorpus.load()
        return try ModelCapabilityResolver(knowledgeBase: document.knowledgeBase)
    }
}
