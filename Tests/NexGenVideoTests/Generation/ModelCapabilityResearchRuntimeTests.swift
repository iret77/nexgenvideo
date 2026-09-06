import Foundation
import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Model capability research runtime")
struct ModelCapabilityResearchRuntimeTests {
    @Test("accepted fields enter routing while the resolved endpoint remains authoritative")
    func acceptedFieldsRespectResolvedEndpointBoundary() throws {
        let corpus = try BundledModelCapabilityCorpus.load()
        let identity = ModelCapabilityIdentityV1(
            familyID: "gemini-image",
            variantID: "flash",
            versionID: "2.5",
            modality: .image
        )
        let offering = CapabilityOfferingIdentityV1(
            providerID: "google",
            offeringID: "google/api/gemini-2.5-flash-image/nano-banana",
            endpointID: "gemini-2.5-flash-image",
            catalogModelID: "nano-banana",
            modality: .image
        )
        let curatedEvidence = CapabilityEvidenceV1(
            sourceURL: "https://ai.google.dev/gemini-api/docs/image-generation",
            sourceTitle: "Bundled Gemini image documentation",
            observedAt: "2026-08-01",
            kind: .documentedAPI,
            confidence: 0.8
        )
        let endpointEvidence = CapabilityEvidenceV1(
            sourceURL: "https://ai.google.dev/gemini-api/docs/image-generation",
            sourceTitle: "Live Gemini endpoint schema",
            observedAt: "2026-09-01",
            kind: .providerSchema,
            confidence: 1
        )
        let origin = ResolvedCapabilityOriginV1(
            kind: .inherited,
            profileID: "gemini-image/flash/2",
            versionID: "2"
        )
        let intrinsic = ResolvedCapabilityProfileV1(
            requestedIdentity: identity,
            resolvedIdentity: ModelCapabilityIdentityV1(
                familyID: "gemini-image",
                variantID: "flash",
                versionID: "2",
                modality: .image
            ),
            defensiveProfileID: nil,
            researchNeeded: true,
            fields: ResolvedCapabilityFieldsV1(integers: [
                CapabilityFieldIDV1.imageReferences: ResolvedCapabilityValueV1(
                    value: 4,
                    semantics: .reliableCapacity,
                    origin: origin,
                    evidence: [curatedEvidence]
                ),
            ])
        )
        let effective = ResolvedCapabilityProfileV1(
            requestedIdentity: identity,
            resolvedIdentity: intrinsic.resolvedIdentity,
            defensiveProfileID: nil,
            researchNeeded: true,
            fields: ResolvedCapabilityFieldsV1(integers: [
                CapabilityFieldIDV1.imageReferences: ResolvedCapabilityValueV1(
                    value: 2,
                    semantics: .hardAPILimit,
                    origin: ResolvedCapabilityOriginV1(
                        kind: .endpointOverlay,
                        profileID: origin.profileID,
                        versionID: origin.versionID,
                        endpointID: offering.endpointID
                    ),
                    evidence: [curatedEvidence, endpointEvidence]
                ),
            ])
        )
        let researchedEvidence = CapabilityEvidenceV1(
            sourceURL: "https://ai.google.dev/gemini-api/docs/image-generation",
            sourceTitle: "Gemini API image generation",
            observedAt: "2026-09-02",
            kind: .documentedAPI,
            confidence: 0.96
        )
        let record = ModelCapabilityResearchOverlayRecordV1(
            id: "df1d9d85-0f84-4646-b8ab-21b8156ec8b7",
            binding: ModelCapabilityResearchBindingV1(
                identity: identity,
                providerID: offering.providerID,
                offeringID: offering.offeringID,
                endpointID: offering.endpointID,
                catalogModelID: offering.catalogModelID
            ),
            scope: .intrinsic,
            fields: CapabilityFieldsV1(integers: [
                CapabilityFieldIDV1.imageReferences: EvidencedCapabilityFieldV1(
                    value: 3,
                    semantics: .reliableCapacity,
                    evidence: [researchedEvidence]
                ),
            ]),
            allowedSourceHosts: ["ai.google.dev"],
            acceptedAt: "2026-09-02",
            status: .active
        )

        let resolved = try ModelCatalog.applyingResearchRecords(
            to: ResolvedOfferingCapabilityProfileV1(
                offering: offering,
                intrinsic: intrinsic,
                effective: effective
            ),
            records: [record],
            corpus: corpus,
            now: try #require(ModelCapabilityResearchDatePolicy.date("2026-09-03"))
        )

        #expect(resolved.intrinsic.fields.integers[CapabilityFieldIDV1.imageReferences]?.value == 3)
        #expect(resolved.effective.fields.integers[CapabilityFieldIDV1.imageReferences]?.value == 2)
        #expect(
            resolved.effective.fields.integers[CapabilityFieldIDV1.imageReferences]?.origin.kind
                == .endpointOverlay
        )
    }

    @Test("an unknown defensive model receives a stable provider-bound research identity")
    func unknownModelIdentityIsStable() {
        let offering = CapabilityOfferingIdentityV1(
            providerID: "fal",
            offeringID: "fal/api/vendor/new-model/vendor/new-model",
            endpointID: "vendor/new-model",
            catalogModelID: "vendor/new-model",
            modality: .video
        )
        let profile = ResolvedCapabilityProfileV1(
            requestedIdentity: nil,
            resolvedIdentity: nil,
            defensiveProfileID: "defensive-video-v1",
            researchNeeded: true,
            fields: ResolvedCapabilityFieldsV1()
        )

        let first = ModelCapabilityResearchIdentityPolicy.binding(
            profile: profile,
            offering: offering,
            corpus: nil
        )
        let second = ModelCapabilityResearchIdentityPolicy.binding(
            profile: profile,
            offering: offering,
            corpus: nil
        )

        #expect(first.value == second.value)
        #expect(first.isSynthetic == second.isSynthetic)
        #expect(first.isSynthetic)
        #expect(first.value.identity.familyID.rawValue == "uncurated")
        #expect(first.value.identity.versionID.rawValue == offering.catalogModelID)
    }
}
