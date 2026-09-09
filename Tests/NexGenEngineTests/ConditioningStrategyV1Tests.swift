import Foundation
import Testing
@testable import NexGenEngine

@Suite("Conditioning strategy V1")
struct ConditioningStrategyV1Tests {
    @Test("reference anchors bind exact demands, slots, modes, and bytes")
    func referenceAnchorBindsExactInputs() throws {
        let anchor = binding(
            id: "anchor",
            semanticJobID: CoreReferenceSemanticJobIDV1.referenceAnchor,
            inputSlotID: CoreReferenceInputSlotIDV1.referenceAnchor,
            modeID: "reference-image"
        )
        let strategy = ShotConditioningStrategyV1(
            shotID: "s001",
            strategy: .referenceAnchor,
            rationale: "Use the approved composition anchor.",
            modeIDs: ["reference-image"],
            referenceAnchors: [conditioningAsset(anchor)]
        )

        try ConditioningStrategyValidatorV1.validate(
            strategy,
            referencePlan: plan(bindings: [anchor])
        )

        let changedBytes = ConditioningAssetBindingV1(
            demandID: anchor.demandID,
            path: anchor.path,
            sha256: hash("f"),
            modality: anchor.modality,
            semanticJobID: anchor.semanticJobID,
            inputSlotID: anchor.inputSlotID
        )
        let invalid = ShotConditioningStrategyV1(
            shotID: strategy.shotID,
            strategy: strategy.strategy,
            rationale: strategy.rationale,
            modeIDs: strategy.modeIDs,
            referenceAnchors: [changedBytes]
        )
        #expect(throws: ConditioningStrategyValidationErrorV1.self) {
            try ConditioningStrategyValidatorV1.validate(
                invalid,
                referencePlan: plan(bindings: [anchor])
            )
        }
    }

    @Test("two-state interpolation uses exactly the first and last frame modes")
    func twoStateBindsBothModes() throws {
        let first = binding(
            id: "first",
            semanticJobID: CoreReferenceSemanticJobIDV1.firstFrame,
            inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
            modeID: "first-frame"
        )
        let last = binding(
            id: "last",
            semanticJobID: CoreReferenceSemanticJobIDV1.lastFrame,
            inputSlotID: CoreReferenceInputSlotIDV1.lastFrame,
            modeID: "last-frame"
        )
        let strategy = ShotConditioningStrategyV1(
            shotID: "s001",
            strategy: .twoStateInterpolation,
            rationale: "Interpolate between approved boundary states.",
            modeIDs: ["last-frame", "first-frame"]
        )
        let referencePlan = plan(bindings: [first, last])

        try ConditioningStrategyValidatorV1.validate(strategy, referencePlan: referencePlan)

        let missingMode = ShotConditioningStrategyV1(
            shotID: strategy.shotID,
            strategy: strategy.strategy,
            rationale: strategy.rationale,
            modeIDs: ["first-frame"]
        )
        #expect(throws: ConditioningStrategyValidationErrorV1.self) {
            try ConditioningStrategyValidatorV1.validate(
                missingMode,
                referencePlan: referencePlan
            )
        }
    }

    @Test("frame continuation accepts only the declared predecessor boundary")
    func continuationBindsPredecessor() throws {
        let predecessor = binding(
            id: "predecessor",
            semanticJobID: CoreReferenceSemanticJobIDV1.predecessorLastFrame,
            inputSlotID: CoreReferenceInputSlotIDV1.firstFrame,
            modeID: "continuation-frame",
            expectedSourceShotID: "s000"
        )
        let strategy = ShotConditioningStrategyV1(
            shotID: "s001",
            strategy: .frameContinuation,
            rationale: "Continue the prior shot without substitution.",
            modeIDs: ["continuation-frame"],
            predecessorShotID: "s000"
        )

        try ConditioningStrategyValidatorV1.validate(
            strategy,
            referencePlan: plan(bindings: [predecessor])
        )

        let wrongPredecessor = ShotConditioningStrategyV1(
            shotID: strategy.shotID,
            strategy: strategy.strategy,
            rationale: strategy.rationale,
            modeIDs: strategy.modeIDs,
            predecessorShotID: "unrelated-shot"
        )
        #expect(throws: ConditioningStrategyValidationErrorV1.self) {
            try ConditioningStrategyValidatorV1.validate(
                wrongPredecessor,
                referencePlan: plan(bindings: [predecessor])
            )
        }
    }

    @Test("native extension binds the exact source video and retained references")
    func nativeExtensionBindsSourceAndReferences() throws {
        let source = binding(
            id: "source",
            path: "media/source.mov",
            sha256: hash("d"),
            modality: .video,
            semanticJobID: CoreReferenceSemanticJobIDV1.sourceVideo,
            inputSlotID: CoreReferenceInputSlotIDV1.sourceVideo,
            modeID: "video-extension"
        )
        let retained = binding(
            id: "retained",
            semanticJobID: CoreReferenceSemanticJobIDV1.referenceAnchor,
            inputSlotID: CoreReferenceInputSlotIDV1.referenceAnchor,
            modeID: "identity-reference"
        )
        let strategy = ShotConditioningStrategyV1(
            shotID: "s001",
            strategy: .nativeExtension,
            rationale: "Extend the approved source while retaining identity.",
            modeIDs: ["video-extension", "identity-reference"],
            sourceVideo: conditioningAsset(source, includeDemandID: false),
            sourceShotID: "s001",
            direction: .forward,
            boundaryStateID: "out-state",
            originalReferenceDemandIDs: [retained.demandID]
        )
        let referencePlan = plan(bindings: [source, retained])

        try ConditioningStrategyValidatorV1.validate(strategy, referencePlan: referencePlan)

        let changedSource = ConditioningAssetBindingV1(
            path: source.path,
            sha256: hash("e"),
            modality: .video,
            semanticJobID: source.semanticJobID,
            inputSlotID: source.inputSlotID
        )
        let invalid = ShotConditioningStrategyV1(
            shotID: strategy.shotID,
            strategy: strategy.strategy,
            rationale: strategy.rationale,
            modeIDs: strategy.modeIDs,
            sourceVideo: changedSource,
            sourceShotID: strategy.sourceShotID,
            direction: strategy.direction,
            boundaryStateID: strategy.boundaryStateID,
            originalReferenceDemandIDs: strategy.originalReferenceDemandIDs
        )
        #expect(throws: ConditioningStrategyValidationErrorV1.self) {
            try ConditioningStrategyValidatorV1.validate(invalid, referencePlan: referencePlan)
        }
    }

    @Test("direction changes invalidate canonical strategy identity")
    func directionIsIdentityBound() throws {
        let source = ConditioningAssetBindingV1(
            path: "media/source.mov",
            sha256: hash("d"),
            modality: .video,
            semanticJobID: CoreReferenceSemanticJobIDV1.sourceVideo,
            inputSlotID: CoreReferenceInputSlotIDV1.sourceVideo
        )
        let forward = ShotConditioningStrategyV1(
            shotID: "s001",
            strategy: .nativeExtension,
            rationale: "Extend from the approved end state.",
            modeIDs: ["video-extension"],
            sourceVideo: source,
            sourceShotID: "s001",
            direction: .forward,
            boundaryStateID: "out-state"
        )
        let identified = try ConditioningStrategyCanonicalCodecV1.identified(
            projectID: "demo",
            shotlistSHA256: hash("a"),
            strategies: [forward]
        )
        let backward = ShotConditioningStrategyV1(
            shotID: forward.shotID,
            strategy: forward.strategy,
            rationale: forward.rationale,
            modeIDs: forward.modeIDs,
            sourceVideo: source,
            sourceShotID: forward.sourceShotID,
            direction: .backward,
            boundaryStateID: forward.boundaryStateID
        )
        let tampered = ConditioningStrategyPlanV1(
            id: identified.id,
            projectID: identified.projectID,
            shotlistSHA256: identified.shotlistSHA256,
            strategies: [backward]
        )

        #expect(throws: ConditioningStrategyValidationErrorV1.self) {
            try ConditioningStrategyValidatorV1.validate(tampered)
        }
    }

    private func plan(bindings: [ReferenceBindingV2]) -> ReferencePlanV2 {
        let imageCount = bindings.filter { $0.modality == .image }.count
        let videoCount = bindings.filter { $0.modality == .video }.count
        return ReferencePlanV2(
            id: "reference-plan-s001",
            projectID: "demo",
            shotID: "s001",
            demandSet: CanonicalArtifactReferenceV1(
                id: "demands-s001",
                role: ReferenceDemandSetV1.artifactRole,
                path: "pipeline/reference-demands/s001.json",
                sha256: hash("a")
            ),
            route: ReferencePlanRouteBindingV2(
                offering: CapabilityOfferingIdentityV1(
                    providerID: "fixture-provider",
                    offeringID: "fixture-provider/video",
                    endpointID: "video",
                    catalogModelID: "fixture/video",
                    modality: .video
                ),
                requirementSHA256: hash("b"),
                capabilitiesSHA256: hash("c"),
                routeSHA256: hash("d")
            ),
            budget: ReferencePlanBudgetV2(
                imageCount: imageCount,
                videoCount: videoCount,
                audioCount: 0,
                geometryCount: 0,
                totalCount: bindings.count
            ),
            bindings: bindings,
            optionalDrops: []
        )
    }

    private func binding(
        id: String,
        path: String? = nil,
        sha256: String? = nil,
        modality: AssetPhysicalModalityV1 = .image,
        semanticJobID: String,
        inputSlotID: String,
        modeID: String,
        expectedSourceShotID: String? = nil
    ) -> ReferenceBindingV2 {
        let demand = ReferenceDemandV1(
            id: "demand-\(id)",
            assetID: "asset-\(id)",
            modality: modality,
            semanticJobID: semanticJobID,
            isRequired: true,
            priority: 100,
            inputSlotID: inputSlotID,
            modeID: modeID,
            expectedSourceShotID: expectedSourceShotID
        )
        let asset = AssetGraphNodeV1(
            id: demand.assetID,
            version: 1,
            path: path ?? "refs/\(id).png",
            sha256: sha256 ?? hash("c"),
            modality: modality,
            approval: .approved,
            provenance: AssetProvenanceV1(
                kindID: "fixture.import",
                recordedAt: "2026-09-09T00:00:00Z"
            ),
            allowedUseIDs: [semanticJobID]
        )
        return ReferenceBindingV2(demand: demand, asset: asset)
    }

    private func conditioningAsset(
        _ binding: ReferenceBindingV2,
        includeDemandID: Bool = true
    ) -> ConditioningAssetBindingV1 {
        ConditioningAssetBindingV1(
            demandID: includeDemandID ? binding.demandID : nil,
            path: binding.path,
            sha256: binding.sha256,
            modality: binding.modality,
            semanticJobID: binding.semanticJobID,
            inputSlotID: binding.inputSlotID
        )
    }

    private func hash(_ value: String) -> String {
        String(repeating: value, count: 64)
    }
}
