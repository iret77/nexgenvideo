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

    static func requireCurrent(_ audit: FrameAudit, dataRoot: URL) throws {
        guard let shot = try loadShotlist(dataRoot: dataRoot)?.shots.first(where: { $0.id == audit.shotId }) else {
            throw ToolError("The audited shot is missing from the current Shot List.")
        }
        let briefPath = PipelineLayout.url(PipelineLayout.briefFile, in: dataRoot)
        let brief = FileManager.default.fileExists(atPath: briefPath.path)
            ? try YAMLArtifactStore(dataRoot: dataRoot).load(Brief.self, at: PipelineLayout.briefFile) : nil
        let expected = try make(shot: shot, role: audit.role,
            execution: executionShot(shotID: audit.shotId, role: audit.role, dataRoot: dataRoot),
            brief: brief, bible: loadBible(dataRoot: dataRoot),
            boundary: boundary(shotID: audit.shotId, role: audit.role, dataRoot: dataRoot))
        guard expected.allSatisfy({ audit.checks[$0.key]?.expected == $0.value }) else {
            throw ToolError("The frame audit uses an earlier shot plan. Inspect and audit the current frame before accepting deviations.")
        }
    }

    static func boundary(shotID: String, role: String, dataRoot: URL) throws -> FrameBoundaryInput? {
        let path = PipelineLayout.url(PipelineLayout.executionShotInputsFile, in: dataRoot)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let input = try PipelineExecutionShotInputStore.loadCurrent(dataRoot: dataRoot).executionShots.first { $0.id == shotID }
        return role == "end" ? input?.endState.frameBoundary : input?.startState.frameBoundary
    }

    static func make(shot: Shot, role: String, execution: ExecutionShotV1?, brief: Brief?, bible: Bible?, boundary: FrameBoundaryInput? = nil) throws -> [String: String] {
        guard role == "start" || role == "end", execution == nil || execution?.id == shot.id else {
            throw ToolError("Frame audit role or execution shot does not match the shot.")
        }
        let blocking = shot.characterBlocking
        var forbidden = ["no characters beyond declared character_refs"]
        if !(brief?.allowTextOverlays ?? false) { forbidden.insert("no text overlays / title cards", at: 0) }
        let anchor = bible?.locations.first(where: { $0.id == shot.locationRef })?.proportionAnchorShot
        let characterPositions = blocking.map { item -> String in
            let setAnchor = shot.productionPlan?.setAnchor(
                for: item.characterRef
            ) ?? ""
            return "\(item.characterRef)@\(item.position) (\(item.pose), "
                + "anchor=\(setAnchor), relation=\(item.relationToSet))"
        }.joined(separator: "; ")
        let gazes = blocking.map {
            "\($0.characterRef): \($0.gaze)"
        }.joined(separator: "; ")
        let characterCount = ProductionDiscipline.visibleCharacterCount(
            shot,
            bible: bible
        )
        var result: [String: String] = [
            "character_count": String(characterCount),
            "framing": shot.framing?.rawValue ?? "",
            "camera_angle": shot.cameraSetup?.angle.rawValue ?? "",
            "camera_height": shot.cameraSetup?.height.rawValue ?? "",
            "character_position": characterPositions,
            "gaze": gazes,
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
                guard let boundary else {
                    throw ToolError("The end frame needs explicit end_state.frame_boundary in the approved Shot List. Rewind and declare its visible character count, positions, gaze, zones and camera before auditing; do not infer them from the start state.")
                }
                try boundary.validate()
                result["character_count"] = String(boundary.characterCount)
                result["character_position"] = boundary.characterPositions
                result["gaze"] = boundary.gaze
                result["visible_zones"] = boundary.visibleZones.joined(separator: ", ")
                let isStatic = execution.camera.movementID == CameraMovement.static.rawValue
                guard isStatic || (boundary.framing != nil && boundary.cameraAngle != nil && boundary.cameraHeight != nil) else {
                    throw ToolError("A moving camera requires distinct end framing, cameraAngle and cameraHeight in end_state.frame_boundary.")
                }
                if let framing = boundary.framing { result["framing"] = framing }
                if let angle = boundary.cameraAngle { result["camera_angle"] = angle }
                if let height = boundary.cameraHeight { result["camera_height"] = height }
            }
        } else if role == "end" {
            throw ToolError("An end-frame audit requires a declared execution end state.")
        }
        return result
    }
}
