import Foundation
import Testing
@testable import NexGenEngine

@Suite("Partial Treatment chronology")
struct TreatmentCausalityV2Tests {
    @Test func temporalChangeMarksBothAffectedBeatsWithoutInventingOrder() {
        let previous = plan(relations: [])
        let revised = plan(relations: [.init(firstBeatID: "a", secondBeatID: "b", kind: .parallel, reason: "Same world time")])
        #expect(revised.affectedBeats(comparedWith: previous) == Set(["a", "b"]))
    }

    @Test func parallelEventsNeedNoInventedTotalOrder() throws {
        let value = plan(relations: [.init(firstBeatID: "a", secondBeatID: "b", kind: .parallel, reason: "Independent simultaneous events")])
        try value.validate(treatmentBody: "Event A. Event B. Event C.", approval: true)
    }

    @Test func knownBeforeCycleIsRejected() throws {
        let value = plan(relations: [
            .init(firstBeatID: "a", secondBeatID: "b", kind: .before, reason: "First relation"),
            .init(firstBeatID: "b", secondBeatID: "c", kind: .before, reason: "Second relation"),
            .init(firstBeatID: "c", secondBeatID: "a", kind: .before, reason: "Cycle"),
        ])
        #expect(throws: ProductionPlanningError.self) { try value.validate(treatmentBody: "Event A. Event B. Event C.") }
    }

    @Test func unknownRelationCannotContradictTransitiveKnownOrder() throws {
        let value = plan(relations: [
            .init(firstBeatID: "a", secondBeatID: "c", kind: .before, reason: "A before C"),
            .init(firstBeatID: "c", secondBeatID: "b", kind: .before, reason: "C before B"),
            .init(firstBeatID: "a", secondBeatID: "b", kind: .unknown, reason: "Cannot be unknown"),
        ])
        #expect(throws: ProductionPlanningError.self) { try value.validate(treatmentBody: "Event A. Event B. Event C.") }
    }

    private func plan(relations: [TreatmentCausalityV2.TemporalRelation]) -> TreatmentCausalityV2 {
        let refs = [reference("treatment", PipelineLayout.treatmentVersionFile(1)),
                    reference("brief", PipelineLayout.briefFile), reference("source", StorySourceV1.currentPath)]
        let header = PlanningArtifactHeaderV1(projectID: "fixture", revision: 1, origin: .agentProposal, inputs: refs)
        let review = StoryCausalityDraftV1.ChangeReview(reviewer: "fixture", upstreamCause: "Approved source",
            downstreamConsequence: "Preserved events", affectedBeatIDs: ["a", "b", "c"],
            checks: StoryCausalityDraftV1.ReviewQuestion.allCases.map {
                .init(question: $0, verdict: .satisfied, explanation: "Explicitly checked")
            })
        return TreatmentCausalityV2(header: header, treatmentReference: refs[0], briefReference: refs[1], storySourceReference: refs[2],
            mode: .abstract, applicationReason: "Independent imagery", beats: [
                .init(id: "a", sceneID: "scene-a", excerpt: "Event A.", elementIDs: []),
                .init(id: "b", sceneID: "scene-b", excerpt: "Event B.", elementIDs: []),
                .init(id: "c", sceneID: "scene-c", excerpt: "Event C.", elementIDs: []),
            ], edges: [], temporalRelations: relations, elements: [], stateChanges: [], unresolvedDecisions: [], changeReview: review)
    }

    private func reference(_ id: String, _ path: String) -> CanonicalArtifactReferenceV1 {
        .init(id: id, role: "core.fixture", path: path, sha256: String(repeating: "0", count: 64))
    }
}
