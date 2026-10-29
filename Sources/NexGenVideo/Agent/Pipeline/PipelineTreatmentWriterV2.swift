import Foundation
import NexGenEngine

enum PipelineTreatmentWriterV2 {
    struct CausalityProposal: Codable {
        let mode: StoryCausalityDraftV1.Mode
        let applicationReason: String
        let beats: [TreatmentCausalityV2.Beat]
        let edges: [TreatmentCausalityV2.CausalEdge]
        let temporalRelations: [TreatmentCausalityV2.TemporalRelation]
        let elements: [StoryCausalityDraftV1.Element]
        let stateChanges: [StoryCausalityDraftV1.StateChange]
        let unresolvedDecisions: [StoryCausalityDraftV1.Decision]
        let changeReview: StoryCausalityDraftV1.ChangeReview
    }

    static func write(treatment: Treatment, proposal: CausalityProposal,
                      access: PipelinePlanningWriteAccess) throws -> TreatmentCausalityV2 {
        guard access.phase == "treatment" else { throw GateBlocked("Treatment has a different phase owner.") }
        let root = access.dataRoot
        let revision = TreatmentStore.nextVersion(dataRoot: root)
        guard treatment.meta.version == revision else { throw GateBlocked("Treatment revisions cannot overwrite history.") }
        let previous = try TreatmentCausalityStoreV2.history(dataRoot: root, through: revision - 1)
        let source = try PlanningWriterIO.read(StorySourceV1.self, at: StorySourceV1.currentPath, dataRoot: root)
        try PipelineStorySourceWriter.requireConfirmed(source, workflowID: access.workflow.contractID, dataRoot: root)
        let treatmentBytes = Data(try treatment.serialized().utf8)
        let treatmentReference = PlanningWriterIO.reference(PipelineLayout.treatmentVersionFile(revision),
            id: "treatment", role: "core.treatment", bytes: treatmentBytes)
        let brief = try PlanningWriterIO.reference(PipelineLayout.briefFile, id: "brief", role: "core.brief", dataRoot: root)
        let sourceReference = try PlanningWriterIO.reference(StorySourceV1.currentPath,
            id: "story-source.binding", role: "core.story-source", dataRoot: root)
        var inputs = [treatmentReference, brief, sourceReference]
        if let previous {
            inputs.append(try PlanningWriterIO.reference(TreatmentCausalityV2.versionPath(previous.header.revision),
                id: "treatment.prior-causality", role: "core.treatment-history", dataRoot: root))
        }
        let origin: PlanningArtifactHeaderV1.Origin
        switch treatment.meta.origin {
        case .agentProposal: origin = .agentProposal
        case .agentRevision: origin = .agentRevision
        case .userSupplied: origin = .userSupplied
        case .userRevision: origin = .userRevision
        }
        func artifact(_ review: StoryCausalityDraftV1.ChangeReview) -> TreatmentCausalityV2 {
            TreatmentCausalityV2(header: .init(projectID: treatment.meta.project, revision: revision,
            origin: origin, inputs: inputs), treatmentReference: treatmentReference, briefReference: brief,
            storySourceReference: sourceReference, mode: proposal.mode, applicationReason: proposal.applicationReason,
            beats: proposal.beats, edges: proposal.edges, temporalRelations: proposal.temporalRelations,
            elements: proposal.elements, stateChanges: proposal.stateChanges, unresolvedDecisions: proposal.unresolvedDecisions,
            changeReview: review)
        }
        let proposed = artifact(proposal.changeReview)
        var review = try JSONSerialization.jsonObject(with: PlanningWriterIO.json(proposal.changeReview)) as? [String: Any] ?? [:]
        review["affectedBeatIDs"] = Set(proposal.changeReview.affectedBeatIDs).union(proposed.affectedBeats(comparedWith: previous)).sorted()
        let recordedReview = try JSONDecoder().decode(StoryCausalityDraftV1.ChangeReview.self,
            from: JSONSerialization.data(withJSONObject: review))
        let value = artifact(recordedReview)
        try value.validate(treatmentBody: treatment.bodyMarkdown, previous: previous, approval: false)
        let bytes = try PlanningWriterIO.json(value)
        try access.publish([(PipelineLayout.treatmentVersionFile(revision), treatmentBytes),
            (PipelineLayout.treatmentCurrentFile, treatmentBytes), (TreatmentCausalityV2.versionPath(revision), bytes),
            (TreatmentCausalityV2.currentPath, bytes)]) {
                _ = try TreatmentCausalityStoreV2.requireCurrent(dataRoot: root, approval: false)
        }
        return value
    }
}
