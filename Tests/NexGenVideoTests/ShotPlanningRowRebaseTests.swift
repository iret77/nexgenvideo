import NexGenEngine
import Testing
@testable import NexGenVideo

@Suite("Shot Planning row rebase")
struct ShotPlanningRowRebaseTests {
    private let framing = StoryboardTimingV1.FramingIntent(scale: "wide", composition: "center", cameraView: "front")
    private let a = "00000000-0000-4000-8000-00000000000a"
    private let b = "00000000-0000-4000-8000-00000000000b"
    private let source = CanonicalArtifactReferenceV1(id: "source-a", role: "core.source-footage",
        path: "shot-planning/sources/a/source.mov", sha256: String(repeating: "a", count: 64))

    private func generated(_ id: String, movement: CameraMovement = .static,
                           chain: ShotPlanningDraftV1.ShotIntent.ChainKind = .none, predecessor: String? = nil) -> ShotPlanningDraftV1.ShotIntent {
        .init(shotID: id, sourceMode: .generated, camera: .init(framing: framing, movement: movement),
              obligations: [], chainKind: chain, predecessorShotID: predecessor)
    }

    private func imported(_ id: String) -> ShotPlanningDraftV1.ShotIntent {
        .init(shotID: id, sourceMode: .imported, source: source, camera: .init(framing: framing, movement: .static), obligations: [])
    }

    private func draft(_ revision: Int, _ shots: [ShotPlanningDraftV1.ShotIntent], inputs: [CanonicalArtifactReferenceV1] = [],
                       storyboard: Int = 1) -> ShotPlanningDraftV1 {
        .init(header: .init(projectID: "fixture", revision: revision, origin: .userRevision, inputs: inputs),
              storyboardRevision: storyboard, shots: shots)
    }

    @Test func anotherShotAttachingASourceReloadsAnUneditedRowAndRebasesAnEditedOne() {
        let baseline = draft(1, [generated(a), generated(b)])
        let latest = draft(2, [imported(a), generated(b)], inputs: [source])
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: latest,
            hasLocalEdits: false, chosenPredecessorID: nil) == .reload)
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: latest,
            hasLocalEdits: true, chosenPredecessorID: nil) == .rebaseKeepingEdits)
    }

    @Test func ownShotChangedUnderLocalEditsIsAConflict() {
        let baseline = draft(1, [generated(a), generated(b)])
        let latest = draft(2, [generated(a), generated(b, movement: .pan)])
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: latest,
            hasLocalEdits: true, chosenPredecessorID: nil) == .conflict(.shotChanged))
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: latest,
            hasLocalEdits: false, chosenPredecessorID: nil) == .reload)
    }

    @Test func chosenPredecessorLeavingGenerationIsAConflict() {
        let baseline = draft(1, [generated(a), generated(b)])
        let latest = draft(2, [imported(a), generated(b)], inputs: [source])
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: latest,
            hasLocalEdits: true, chosenPredecessorID: a) == .conflict(.predecessorUnavailable))
        let removed = draft(2, [generated(b)])
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: removed,
            hasLocalEdits: true, chosenPredecessorID: a) == .conflict(.predecessorUnavailable))
    }

    @Test func storyboardRevisionChangeUnderLocalEditsIsAConflict() {
        let baseline = draft(1, [generated(a), generated(b)])
        let latest = draft(2, [generated(a), generated(b)], storyboard: 2)
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: latest,
            hasLocalEdits: true, chosenPredecessorID: nil) == .conflict(.storyboardChanged))
    }

    @Test func ownOrOlderRevisionsLeaveTheRowUnchanged() {
        let baseline = draft(2, [generated(a), generated(b)])
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: baseline,
            hasLocalEdits: true, chosenPredecessorID: nil) == .current)
        #expect(ShotPlanningRowRebase.decide(shotID: b, baseline: baseline, latest: draft(1, [imported(a), generated(b)]),
            hasLocalEdits: false, chosenPredecessorID: nil) == .current)
    }
}
