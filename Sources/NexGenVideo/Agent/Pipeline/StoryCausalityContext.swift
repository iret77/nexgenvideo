import Foundation
import NexGenEngine

enum StoryCausalityContext {
    static func prompt(dataRoot: URL, phase: String) -> String? {
        guard ["treatment", "storyboard", "bible", "shotlist", "sanity", "frames", "render"].contains(phase) else { return nil }
        let contract = """
        Story causality contract:
        write_treatment requires causality_plan: stable beat and scene IDs, exact body excerpts, independent story chronology, therefore/but edges, introduced elements and payoffs, visible state changes and attributed answers to all eight change-review questions. Use the Brief concept type; performance and abstract films need their own progression rather than invented plot causality. Mark unresolved canon alternatives explicitly; Treatment cannot be approved until resolved. Drafts may contain attributed concerns; structural validation is not a dramaturgical quality verdict. Do not request another startup interview. Develop proposals from approved material, asking only for genuine unresolved canon choices. Changes to approved truth require explicit rewind.
        When Treatment has a causality plan, write_storyboard requires causality_bindings for every step; story steps cite existing beat IDs, other steps explain their adaptation role. Preserve every approved beat or explicitly revise Treatment. write_shotlist execution_shots require storyboard_step_ids; preserve approved step coverage. A change in source bytes invalidates downstream plans. Read the Treatment with show_artifact to inspect the complete graph, findings and alternatives before revision.
        """
        do {
            let plan = try StoryCausalityStoreV1.requireCurrent(dataRoot: dataRoot, approval: false)
            guard let plan else { return contract }
            return contract + "\nCurrent Treatment causality: v\(plan.treatmentVersion), \(plan.draft.beats.count) beats, \(plan.draft.unresolvedDecisions.count) unresolved decisions."
        } catch {
            return contract + "\nCurrent causality is unavailable: \(error.localizedDescription). Diagnosis and explicit rewind remain available; do not conceal this by dropping the plan."
        }
    }
}
