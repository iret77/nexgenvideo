import Foundation
import Testing
@testable import NexGenEngine

@Suite("Canonical planning source choice before promotion")
struct ShotPlanningSourceShapeTests {
    private let shotID = "shot-00000000-0000-0000-0000-000000000001"
    private let source = CanonicalArtifactReferenceV1(id: "native-source", role: "core.source-footage",
        path: "sources/native.mov", sha256: String(repeating: "a", count: 64))
    private let framing = StoryboardTimingV1.FramingIntent(scale: "wide", composition: "doorway", cameraView: "front")

    @Test func existingGreenfieldImportAndAIEnhancedObligationsRemainValid() throws {
        for mode in [SourceMode.imported, .aiEnhanced] {
            try validate(mode: mode, obligationID: "source", obligations: [obligation("source")])
        }
    }

    @Test func explicitNativeSourceAndRangeRemainValidAtApproval() throws {
        for mode in [SourceMode.imported, .aiEnhanced] {
            try validate(mode: mode, explicitSource: source, obligations: [], approval: true)
        }
        try validate(mode: .generated, obligations: [])
    }

    @Test func generatedCannotOfferAnUnconsumedSourceFootageAssignment() {
        #expect(throws: ProductionPlanningError.invalid("shotPlanning.generatedSource")) {
            try validate(mode: .generated, obligations: [obligation("source")])
        }
    }

    @Test func additionalSourceObligationsPreserveTheCanonicalSourceChoice() throws {
        for mode in [SourceMode.imported, .aiEnhanced] {
            try validate(mode: mode, obligationID: "source", obligations: [obligation("source"), obligation("other")])
            try validate(mode: mode, explicitSource: source, obligations: [obligation("other")], approval: true)
            try validate(mode: mode, obligationID: "source",
                obligations: [obligation("source"), obligation("optional", required: false)])
        }
        try validate(mode: .generated, obligations: [obligation("optional", required: false)])
    }

    @Test func canonicalSourceMustBeUnambiguousAndItsDeclaredObligationRequired() {
        for mode in [SourceMode.imported, .aiEnhanced] {
            #expect(throws: ProductionPlanningError.invalid("shotPlanning.sourceObligation")) {
                try validate(mode: mode, obligationID: "source", obligations: [obligation("other")])
            }
            #expect(throws: ProductionPlanningError.invalid("shotPlanning.sourceObligation")) {
                try validate(mode: mode, obligationID: "source", obligations: [obligation("source", required: false)])
            }
            #expect(throws: ProductionPlanningError.invalid("shotPlanning.sourceChoice")) {
                try validate(mode: mode, explicitSource: source, obligationID: "source", obligations: [obligation("source")])
            }
            #expect(throws: ProductionPlanningError.invalid("shotPlanning.sourceChoice")) {
                try validate(mode: mode, obligations: [])
            }
        }
    }

    @Test func additionalAssetResolutionCannotReplaceTheSelectedSource() throws {
        let extra = obligation("other")
        let asset = AssetGraphNodeV1(id: "video", version: 1, path: source.path, sha256: source.sha256,
            modality: .video, approval: .approved, provenance: .init(kindID: "user-supplied", recordedAt: "fixture"),
            allowedUseIDs: ["source"])
        let bible = try Bible(project: "source-shape", generated: "fixture", generator: "fixture")
        try ShotPlanningPromotionValidatorV1.requireAsset(asset, for: extra, bible: bible, source: source)
        for substituted in [
            CanonicalArtifactReferenceV1(id: source.id, role: source.role, path: "sources/other.mov", sha256: source.sha256),
            CanonicalArtifactReferenceV1(id: source.id, role: source.role, path: source.path, sha256: String(repeating: "b", count: 64))
        ] {
            #expect(throws: ProductionPlanningError.invalid("promotion.sourceFootage")) {
                try ShotPlanningPromotionValidatorV1.requireAsset(asset, for: extra, bible: bible, source: substituted)
            }
        }
    }

    private func obligation(_ id: String, required: Bool = true) -> ShotPlanningDraftV1.Obligation {
        .init(id: id, kind: .sourceFootage, subject: "Recorded performance",
            requirement: "Assign this shot's recorded source", required: required,
            allowedSkipReason: required ? nil : "Use the generated image instead")
    }

    private func validate(mode: SourceMode, explicitSource: CanonicalArtifactReferenceV1? = nil,
                          obligationID: String? = nil, obligations: [ShotPlanningDraftV1.Obligation], approval: Bool = false) throws {
        let header = PlanningArtifactHeaderV1(projectID: "source-shape", revision: 1, origin: .agentProposal,
            inputs: explicitSource.map { [$0] } ?? [])
        let clock = RationalTimebaseV1(ticksPerSecond: 24, fpsNumerator: 24)
        let timing = StoryboardTimingV1(header: header, timebase: clock, mode: .generic, rangeDurationTicks: 72,
            shots: [.init(id: shotID, primaryStepID: "step-a", startTicks: 0, durationTicks: 72, framing: framing, moments: [])])
        let range = explicitSource.map { SourceFootageRangeV1(source: $0, timebase: clock, startTicks: 0, durationTicks: 72) }
        let draft = ShotPlanningDraftV1(header: header, storyboardRevision: 1, shots: [
            .init(shotID: shotID, sourceMode: mode, source: explicitSource, sourceObligationID: obligationID,
                camera: .init(framing: framing, movement: .static), obligations: obligations, sourceInputRange: range)])
        try ShotPlanningValidatorV1.validate(draft, timing: timing, approval: approval)
    }
}
