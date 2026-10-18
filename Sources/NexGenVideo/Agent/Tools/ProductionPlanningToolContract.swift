import Foundation
import NexGenEngine

extension PipelineArtifactWriteContract {
    static var scriptV1Schema: [String: Any] { ProductionPlanningToolContract.script }
    static var storyboardBundleSchema: [String: Any] { ProductionPlanningToolContract.storyboard }
    static var shotPlanningDraftSchema: [String: Any] { ProductionPlanningToolContract.shotPlanning }
}

enum ProductionPlanningToolContract {
    private static var text: [String: Any] { ["type": "string", "minLength": 1] }
    private static var integer: [String: Any] { ["type": "integer"] }
    private static var boolean: [String: Any] { ["type": "boolean"] }
    private static var origins: [String: Any] { enumeration(["agentProposal", "agentRevision"]) }
    private static var reference: [String: Any] { object([
        "id": text, "role": text, "path": text, "sha256": ["type": "string", "pattern": "^[a-f0-9]{64}$"],
    ], required: ["id", "role", "path", "sha256"]) }
    private static var timebase: [String: Any] { object([
        "ticksPerSecond": integer, "fpsNumerator": integer, "fpsDenominator": integer,
    ], required: ["ticksPerSecond", "fpsNumerator", "fpsDenominator"]) }
    private static var framing: [String: Any] { object([
        "scale": text, "composition": text, "cameraView": text,
    ], required: ["scale", "composition", "cameraView"]) }

    static var script: [String: Any] { object([
        "project_dir": text, "origin": origins, "summary": text,
        "scenes": array(object([
            "id": text, "title": text, "adaptation": text,
            "events": array(object([
                "id": text, "action": text, "dialogue": text,
                "treatmentBeatIDs": array(text, minimum: 1),
                "sourceAnchors": array(object([
                    "sourceID": text, "startByte": integer, "endByte": integer,
                    "excerptSHA256": ["type": "string", "pattern": "^[a-f0-9]{64}$"],
                ], required: ["sourceID", "startByte", "endByte", "excerptSHA256"])),
            ], required: ["id", "action", "treatmentBeatIDs", "sourceAnchors"]), minimum: 1),
        ], required: ["id", "title", "adaptation", "events"]), minimum: 1),
    ], required: ["origin", "summary", "scenes"]) }

    static var storyboard: [String: Any] { object([
        "project_dir": text, "origin": origins,
        "proposal": object([
            "summary": text,
            "steps": array(object([
                "id": text, "sceneID": text, "eventIDs": array(text, minimum: 1),
                "function": enumeration(StepFunction.allCases.map(\.rawValue)), "action": text,
            ], required: ["id", "sceneID", "eventIDs", "function", "action"]), minimum: 1),
            "bindings": array(object([
                "stepID": text, "beatIDs": array(text), "reason": text,
            ], required: ["stepID", "beatIDs", "reason"]), minimum: 1),
            "timebase": timebase, "mode": enumeration(["beat", "section", "multicam", "generic"]),
            "rangeStartTicks": integer, "rangeDurationTicks": integer,
            "audio": object(["source": reference, "offsetTicks": integer, "durationTicks": integer],
                required: ["source", "offsetTicks", "durationTicks"]),
            "shots": array(object([
                "id": text, "primaryStepID": text, "additionalStepIDs": array(text),
                "startTicks": integer, "durationTicks": integer, "cameraID": text, "framing": framing,
                "moments": array(object([
                    "id": text, "offsetTicks": integer, "intent": text,
                    "asset": object(["image": reference, "proof": reference], required: ["image", "proof"]),
                ], required: ["id", "offsetTicks", "intent"])),
            ], required: ["primaryStepID", "additionalStepIDs", "startTicks", "durationTicks", "framing", "moments"]), minimum: 1),
        ], required: ["summary", "steps", "bindings", "timebase", "mode", "rangeStartTicks", "rangeDurationTicks", "shots"]),
    ], required: ["origin", "proposal"]) }

    static var shotPlanning: [String: Any] { object([
        "project_dir": text, "origin": origins,
        "shots": array(object([
            "shotID": text, "narrativeBeat": enumeration(NarrativeBeat.allCases.map(\.rawValue)), "sourceMode": enumeration(SourceMode.allCases.map(\.rawValue)),
            "source": reference, "sourceObligationID": text,
            "camera": object([
                "framing": framing, "movement": enumeration(CameraMovement.allCases.map(\.rawValue)),
                "movementDetail": text, "blocking": array(text), "sceneReference": reference,
            ], required: ["framing", "movement", "blocking"]),
            "obligations": array(object([
                "id": text, "kind": enumeration(["characterIdentity", "locationAppearance", "prop", "look", "geometry", "sourceFootage", "stateVariant"]),
                "subject": text, "requirement": text, "required": boolean, "allowedSkipReason": text,
            ], required: ["id", "kind", "subject", "requirement", "required"])),
            "chainKind": enumeration(["none", "frameContinuation", "nativeExtension"]), "predecessorShotID": text,
        ], required: ["shotID", "sourceMode", "camera", "obligations", "chainKind"]), minimum: 1),
    ], required: ["origin", "shots"]) }

    private static func enumeration(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private static func array(_ items: [String: Any], minimum: Int = 0) -> [String: Any] {
        ["type": "array", "items": items, "minItems": minimum]
    }
    private static func object(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}
