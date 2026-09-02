import Testing
@testable import NexGenEngine

@Suite("Production identifier normalization")
struct ProductionIdentifierNormalizerV1Tests {
    @Test("requirement and demand modes accept underscore-hyphen aliases")
    func requirementDemandModes() throws {
        #expect(ProductionReferenceDemandSemanticsV1.isDedicated(
            semanticJobID: "CORE.AUDIO_TIMING"
        ))
        let demandSet = ReferenceDemandSetV1(
            id: "reference-demands-shot-001",
            projectID: "project-001",
            shotID: "shot-001",
            assetGraph: CanonicalArtifactReferenceV1(
                id: "asset-graph-001",
                role: AssetGraphV1.artifactRole,
                path: PipelineLayout.assetGraphFile,
                sha256: String(repeating: "a", count: 64)
            ),
            demands: [
                ReferenceDemandV1(
                    id: "look-001",
                    assetID: "asset-look-001",
                    modality: .image,
                    semanticJobID: "look.identity",
                    isRequired: true,
                    priority: 1,
                    inputSlotID: "reference.image",
                    modeID: "reference-to-video"
                ),
                ReferenceDemandV1(
                    id: "audio-timing",
                    assetID: "asset-audio-timing",
                    modality: .audio,
                    semanticJobID: CoreReferenceSemanticJobIDV1.audioTiming,
                    isRequired: true,
                    priority: 0,
                    inputSlotID: CoreReferenceInputSlotIDV1.audioTiming,
                    modeID: "reference-to-video"
                ),
            ]
        )
        let requirement = ProductionRequirementV1(
            modalityID: "video",
            modeIDs: ["REFERENCE_TO_VIDEO"],
            visibleEntityCount: 1,
            referenceDemandIDs: ["look-001"],
        )

        try ProductionRequirementResolverV1.validateBindings(
            requirement,
            demandSet: demandSet
        )
        #expect(ReferencePlannerV2.bindingDeficits(
            requirement: requirement,
            demandSet: demandSet
        ).isEmpty)
    }
}
