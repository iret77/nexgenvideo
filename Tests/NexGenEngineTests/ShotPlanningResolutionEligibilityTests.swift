import Testing
@testable import NexGenEngine

@Suite("Native eligibility and promotion share actual asset requirements")
struct ShotPlanningResolutionEligibilityTests {
    private let digest = String(repeating: "1", count: 64)

    @Test func panoramaIsAnAppearanceAnchorButNotAnUnrelatedImage() throws {
        let location = try Location(id: "room", name: "Room", visualPrompt: "A red room",
            referenceImages: ["bible/room/reference.png"], scene3d: .init(panorama: "bible/room/panorama.png"))
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture", locations: [location])
        let obligation = ShotPlanningDraftV1.Obligation(id: "appearance", kind: .locationAppearance,
            subject: "Room", requirement: "The approved room appearance", required: true)
        try ShotPlanningPromotionValidatorV1.requireAsset(asset("bible/room/panorama.png", entity: "room"),
            for: obligation, bible: bible)
        #expect(throws: ProductionPlanningError.invalid("promotion.entityAnchor")) {
            try ShotPlanningPromotionValidatorV1.requireAsset(asset("bible/other.png", entity: "room"),
                for: obligation, bible: bible)
        }
        #expect(throws: ProductionPlanningError.invalid("promotion.actualApprovedAsset")) {
            try ShotPlanningPromotionValidatorV1.requireAsset(asset("bible/room/panorama.png", entity: "room", approval: .pending),
                for: obligation, bible: bible)
        }
    }

    @Test func sourceAssignmentRemainsOpenUntilTheNativeDraftBindsItsExactBytes() throws {
        let bible = try Bible(project: "fixture", generated: "fixture", generator: "fixture")
        let obligation = ShotPlanningDraftV1.Obligation(id: "source", kind: .sourceFootage,
            subject: "Footage", requirement: "Choose the actual source", required: true)
        let video = asset("sources/first.mov", modality: .video)
        try ShotPlanningPromotionValidatorV1.requireAsset(video, for: obligation, bible: bible)
        let source = CanonicalArtifactReferenceV1(id: video.id, role: "core.source-footage", path: video.path, sha256: video.sha256)
        try ShotPlanningPromotionValidatorV1.requireAsset(video, for: obligation, bible: bible, source: source)
        for wrong in [asset("sources/second.mov", modality: .video),
                      asset(video.path, sha256: String(repeating: "2", count: 64), modality: .video)] {
            #expect(throws: ProductionPlanningError.invalid("promotion.sourceFootage")) {
                try ShotPlanningPromotionValidatorV1.requireAsset(wrong, for: obligation, bible: bible, source: source)
            }
        }
    }

    private func asset(_ path: String, sha256: String? = nil, modality: AssetPhysicalModalityV1 = .image,
                       entity: String? = nil, approval: AssetApprovalStateV1 = .approved) -> AssetGraphNodeV1 {
        .init(id: "asset", version: 1, path: path, sha256: sha256 ?? digest, modality: modality,
            entityID: entity, approval: approval, provenance: .init(kindID: "core.planning-asset", recordedAt: "fixture"),
            allowedUseIDs: [CoreReferenceSemanticJobIDV1.referenceAnchor])
    }
}
