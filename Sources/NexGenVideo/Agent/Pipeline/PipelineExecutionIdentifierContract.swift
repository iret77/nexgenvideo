import Foundation
import NexGenEngine

enum PipelineExecutionIdentifierContract {
    static let pattern = #"^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)+$"#

    static func schema(_ description: String) -> [String: Any] {
        ["type": "string", "minLength": 1, "pattern": pattern, "description": description]
    }

    static var roleSchema: [String: Any] {
        [
            "type": "string",
            "enum": ProductionReferenceDemandSemanticsV1.selectableModalities.keys.sorted(),
            "description": "Reference role, not entity kind. Character, location and prop anchors use core.reference-anchor with entity_id; style, lighting, motion and voice references use their core role. Allowed modalities per role: get_project_state.execution_input_contract.reference_roles. First/last-frame, source-video and audio-timing inputs are derived from core_inputs."
        ]
    }

    static var referenceRoles: [String: [String]] {
        ProductionReferenceDemandSemanticsV1.selectableModalities.mapValues {
            $0.map(\.rawValue).sorted()
        }
    }

    static var discovery: [String: Any] {
        [
            "identifier_pattern": pattern,
            "reference_anchor": [
                "semantic_job_id": CoreReferenceSemanticJobIDV1.referenceAnchor,
                "input_slot_id": CoreReferenceInputSlotIDV1.referenceImage,
                "modality": "image",
                "purpose": "Identity, location or prop anchor; bind entity_id and view_id separately. Use a compatible slot/mode from list_models.production_routes."
            ],
            "dedicated_core_jobs": [CoreReferenceSemanticJobIDV1.firstFrame,
                CoreReferenceSemanticJobIDV1.lastFrame, CoreReferenceSemanticJobIDV1.predecessorLastFrame,
                CoreReferenceSemanticJobIDV1.sourceVideo, CoreReferenceSemanticJobIDV1.audioTiming],
            "dedicated_input_rule": "Dedicated jobs are host-derived from shot source, conditioning and core_inputs. Do not duplicate them in reference_demands.",
            "reference_roles": referenceRoles,
            "role_rule": "semantic_job_id must be one of reference_roles with an allowed modality. The Shot List writer rejects any other role.",
            "capability_discovery": "list_models.production_routes exposes the activated offerings with their actual input_slots and mode_ids. A generated video shot with reference_demands needs one activated video route that takes all its required (is_required=true) demands together with its core_inputs and generation_requirement.mode_ids within the route's reference limits: matching input_slot_id, modality and mode_id per input. An is_required=false demand needs an activated route that offers its input_slot_id, modality and mode_id; Render drops it when the chosen route cannot take it. Every mode_id must also be one of the shot's generation_requirement.mode_ids. Pick one route per shot and copy its values unchanged; no user input is needed for these internal identifiers.",
            "retired_input_slots": ProductionInputSlotAliasV1.retiredSlotIDs,
            "retired_slot_rule": "Retired input slots stay readable in stored Shot Lists, but a new write must use the slot they map to."
        ]
    }
}
