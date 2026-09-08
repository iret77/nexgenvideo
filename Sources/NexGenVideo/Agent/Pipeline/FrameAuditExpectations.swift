import Foundation
import NexGenEngine

enum FrameAuditExpectations {
    static func executionShot(shotID: String, role: String, dataRoot: URL) throws -> ExecutionShotV1? {
        let url = PipelineLayout.url(PipelineLayout.executionPlanFile, in: dataRoot)
        let tracePaths = [PipelineLayout.executionShotInputsFile, ExecutionPlanV1.publicationArtifactPath]
        let hasTrace = tracePaths.contains { FileManager.default.fileExists(atPath: PipelineLayout.url($0, in: dataRoot).path) }
        guard FileManager.default.fileExists(atPath: url.path) || hasTrace else {
            guard role == "start" else {
                throw ToolError("An end-frame audit requires a current execution plan with a declared end state.")
            }
            return nil
        }
        try PipelineExecutionPlanWriter.requireCurrent(dataRoot: dataRoot)
        try PipelineExecutionPlanWriter.requireCurrentShotlistBinding(dataRoot: dataRoot)
        let (plan, _) = try PipelineExecutionPlanWriter.load(dataRoot: dataRoot)
        guard let shot = plan.shots.first(where: { $0.id == shotID }) else {
            throw ToolError("The current execution plan has no shot: " + shotID)
        }
        return shot
    }

    static func make(shot: Shot, role: String, execution: ExecutionShotV1?, brief: Brief?, bible: Bible?) throws -> [String: String] {
        guard role == "start" || role == "end", execution == nil || execution?.id == shot.id else {
            throw ToolError("Frame audit role or execution shot does not match the shot.")
        }
        let blocking = shot.characterBlocking
        var forbidden = ["no characters beyond declared character_refs"]
        if !(brief?.allowTextOverlays ?? false) { forbidden.insert("no text overlays / title cards", at: 0) }
        let anchor = bible?.locations.first(where: { $0.id == shot.locationRef })?.proportionAnchorShot
        var result = [
            "character_count": "\(ProductionDiscipline.visibleCharacterCount(shot, bible: bible))",
            "framing": shot.framing?.rawValue ?? "",
            "camera_angle": shot.cameraSetup?.angle.rawValue ?? "",
            "camera_height": shot.cameraSetup?.height.rawValue ?? "",
            "character_position": blocking.map {
                "\($0.characterRef)@\($0.position) (\($0.pose), anchor=\(shot.productionPlan?.setAnchor(for: $0.characterRef) ?? ""), relation=\($0.relationToSet))"
            }.joined(separator: "; "),
            "gaze": blocking.map { "\($0.characterRef): \($0.gaze)" }.joined(separator: "; "),
            "forbidden_elements": forbidden.joined(separator: "; "),
            "visible_zones": shot.visibleZones.joined(separator: ", "),
            "anchor_at_t0": "exact start state: subject in the planned start pose, before the shot's action",
            "proportion_anchor_match": anchor.map { "Match figure-to-set scale in approved shot " + $0 } ?? "",
        ]
        if let execution {
            let state = role == "end" ? execution.endState : execution.startState
            guard !state.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("The execution plan must declare the audited boundary state.")
            }
            let expectedState = ([state.summary, state.spatialState ?? ""]
                + state.entityStateIDs.map { "entity state: " + $0 }).filter { !$0.isEmpty }.joined(separator: "; ")
            // The v1 key stays stable; its expectation follows the audited boundary.
            result["anchor_at_t0"] = "Exact \(role) state: " + expectedState
            if role == "end" {
                result["character_count"] = "Visible characters in the declared end state: " + expectedState
                result["character_position"] = "Positions in the declared end state: " + expectedState
                result["gaze"] = "Gaze only where specified in the declared end state: " + expectedState
                result["visible_zones"] = state.spatialState ?? ""
                let endpoint = execution.camera.endpoint ?? ""
                result["framing"] = endpoint
                result["camera_angle"] = endpoint
                result["camera_height"] = endpoint
            }
        } else if role == "end" {
            throw ToolError("An end-frame audit requires a declared execution end state.")
        }
        return result
    }
}
