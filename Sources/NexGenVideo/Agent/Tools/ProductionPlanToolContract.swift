import Foundation
import NexGenEngine

enum ProductionPlanToolContract {
    private static var text: [String: Any] { ["type": "string", "minLength": 1] }
    private static var integer: [String: Any] { ["type": "integer", "minimum": 0] }
    private static var number: [String: Any] { ["type": "number", "minimum": 0] }
    private static var boolean: [String: Any] { ["type": "boolean"] }
    private static var strings: [String: Any] { array(text) }
    private static var hash: [String: Any] { ["type": "string", "pattern": "^[a-f0-9]{64}$"] }
    private static var reference: [String: Any] { object(["id": text, "role": text, "path": text, "sha256": hash], required: ["id", "role", "path", "sha256"]) }
    private static var timebase: [String: Any] { object(["ticksPerSecond": integer, "fpsNumerator": integer, "fpsDenominator": integer], required: ["ticksPerSecond", "fpsNumerator", "fpsDenominator"]) }

    static var prepareAssets: [String: Any] { object([
        "project_dir": text,
        "assets": array(object([
            "path": text, "modality": enumeration(AssetPhysicalModalityV1.allCases.map(\.rawValue)),
            "entity_id": text, "canon_ids": strings, "state_id": text, "view_id": text,
            "allowed_use_ids": strings, "duration_seconds": number,
        ], required: ["path", "modality", "allowed_use_ids"])),
    ], required: ["assets"]) }

    static var write: [String: Any] { object([
        "project_dir": text, "origin": enumeration(["agentProposal", "agentRevision"]),
        "proposal": object([
            "expectedDraftFingerprint": hash, "expectedAssetGraphFingerprint": hash,
            "shots": array(object([
                "execution": execution, "nativeDurationTicks": integer, "sourceInTicks": integer,
                "sourceInputRange": object(["shotID": text, "source": reference, "timebase": timebase,
                    "startTicks": integer, "durationTicks": integer], required: ["shotID", "source", "timebase", "startTicks", "durationTicks"]),
                "coreInputs": coreInputs, "referenceDemands": array(demand), "selectedModelID": text,
                "selectedOffering": object([
                    "provider_id": text, "offering_id": text, "endpoint_id": text, "catalog_model_id": text,
                    "modality": enumeration(CapabilityModalityV1.allCases.map(\.rawValue)),
                ], required: ["provider_id", "offering_id", "endpoint_id", "catalog_model_id", "modality"]),
            ], required: ["execution", "sourceInTicks", "referenceDemands"]), minimum: 1),
        ], required: ["expectedDraftFingerprint", "expectedAssetGraphFingerprint", "shots"]),
    ], required: ["origin", "proposal"]) }

    private static var state: [String: Any] { object([
        "summary": text, "entity_state_ids": strings, "spatial_state": text,
    ], required: ["summary", "entity_state_ids"]) }

    private static var execution: [String: Any] { object([
        "id": text, "source_mode": enumeration(ExecutionSourceModeV1.allCases.map(\.rawValue)), "source_asset_id": text,
        "start_state": state, "end_state": state, "primary_action": text,
        "camera": object(["movement_id": text, "movement_detail": text, "framing_id": text,
            "placement": text, "endpoint": text], required: ["movement_id"]),
        "blocking": array(object(["entity_id": text, "anchor_asset_id": text, "relation": text, "performance": text],
            required: ["entity_id", "relation"])),
        "timed_action_beats": array(object(["time_seconds": number, "action": text], required: ["time_seconds", "action"])),
        "continuity_locks": strings, "transition_intent": text,
        "renderability": enumeration(["green", "yellow", "red"]), "risks": strings, "rescue": text,
        "acceptance": array(object(["id": text, "requirement": text, "severity": text], required: ["id", "requirement", "severity"]), minimum: 1),
        "generation_requirement": requirement,
    ], required: ["id", "source_mode", "start_state", "end_state", "primary_action", "camera", "blocking", "timed_action_beats", "continuity_locks", "renderability", "risks", "acceptance"]) }

    private static var requirement: [String: Any] { object([
        "modality_id": enumeration([CapabilityModalityV1.video.rawValue]), "mode_ids": array(text, minimum: 1),
        "visible_entity_count": integer, "identity_lock_asset_ids": strings, "reference_demand_ids": strings,
        "requires_first_frame": boolean, "requires_last_frame": boolean, "source_video_asset_id": text,
        "duration": object(["preferred_seconds": number, "minimum_seconds": number, "maximum_seconds": number,
            "allows_automatic": boolean], required: ["allows_automatic"]),
        "resolution": text, "aspect_ratio": text, "requires_output_audio": boolean,
        "production_profile_requirement_ids": strings, "quality_target": text, "maximum_latency_seconds": number,
    ], required: ["modality_id", "mode_ids", "visible_entity_count", "identity_lock_asset_ids", "reference_demand_ids", "requires_first_frame", "requires_last_frame", "requires_output_audio", "production_profile_requirement_ids"]) }

    private static var coreInputs: [String: Any] { object([
        "first_frame_mode_id": text, "last_frame_mode_id": text, "predecessor_last_frame_mode_id": text,
        "source_video_mode_id": text, "audio_timing_mode_id": text,
    ], required: []) }

    private static var demand: [String: Any] { object([
        "id": text, "asset_id": text, "modality": enumeration(AssetPhysicalModalityV1.allCases.map(\.rawValue)),
        "semantic_job_id": PipelineExecutionIdentifierContract.roleSchema, "is_required": boolean, "priority": integer,
        "preservation_scope_ids": strings, "exclusion_demand_ids": strings, "input_slot_id": text, "mode_id": text,
        "duration_seconds": number,
    ], required: ["id", "asset_id", "modality", "semantic_job_id", "is_required", "priority", "preservation_scope_ids", "exclusion_demand_ids", "input_slot_id", "mode_id"]) }

    private static func enumeration(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private static func array(_ items: [String: Any], minimum: Int = 0) -> [String: Any] { ["type": "array", "items": items, "minItems": minimum] }
    private static func object(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}
