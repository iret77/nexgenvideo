import Foundation
import NexGenEngine

extension ToolExecutor {
    func writeScriptTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "script")
        let scenes = try JSONDecoder().decode([ScriptV1.Scene].self, from: JSONSerialization.data(withJSONObject: args["scenes"] as Any))
        let script = try PipelineScriptWriter.write(summary: try args.requireString("summary"), scenes: scenes,
            origin: planningOrigin(args), access: access)
        return try jsonResult(["written": true, "revision": script.header.revision,
            "path": ScriptV1.versionPath(script.header.revision), "current": ScriptV1.currentPath])
    }

    func writeStoryboardBundleTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "storyboard")
        let proposal = try JSONDecoder().decode(PipelineStoryboardBundleWriter.Proposal.self,
            from: JSONSerialization.data(withJSONObject: args["proposal"] as Any))
        let snapshot = try PipelineStoryboardBundleWriter.write(proposal, origin: planningOrigin(args), access: access)
        return try jsonResult(["written": true, "revision": snapshot.storyboard.header.revision,
            "path": StoryboardV2.versionPath(snapshot.storyboard.header.revision), "current": StoryboardV2.currentPath,
            "planned_shot_ids": snapshot.timing.shots.map(\.id), "fingerprint": snapshot.fingerprint])
    }

    func writeShotPlanningDraftTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let access = try planningAccess(editor, args, phase: "shot_planning")
        let shots = try JSONDecoder().decode([ShotPlanningDraftV1.ShotIntent].self,
            from: JSONSerialization.data(withJSONObject: args["shots"] as Any))
        let draft = try PipelineShotPlanningWriter.write(shots: shots, origin: planningOrigin(args), access: access)
        return try jsonResult(["written": true, "revision": draft.header.revision,
            "path": ShotPlanningDraftV1.versionPath(draft.header.revision), "current": ShotPlanningDraftV1.currentPath])
    }

    private func planningAccess(_ editor: EditorViewModel, _ args: [String: Any], phase: String) throws -> PipelinePlanningWriteAccess {
        let root = try resolveDataRoot(args, editor: editor)
        return try PipelinePlanningWriteAccess(dataRoot: root,
            declaration: mutationPackDeclaration(editor, dataRoot: root), phase: phase)
    }

    private func planningOrigin(_ args: [String: Any]) throws -> PlanningArtifactHeaderV1.Origin {
        guard let origin = PlanningArtifactHeaderV1.Origin(rawValue: try args.requireString("origin")),
              origin == .agentProposal || origin == .agentRevision else {
            throw ToolError("Agent writers use agentProposal or agentRevision; native selection and adoption provenance belongs to the host.")
        }
        return origin
    }
}
