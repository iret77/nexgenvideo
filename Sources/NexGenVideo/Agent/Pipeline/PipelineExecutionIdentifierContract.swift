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
            "capability_discovery": "list_models.production_routes exposes the activated offerings with their actual input_slots and mode_ids. For generated video shots the Shot List writer rejects a reference demand whose input_slot_id, modality and mode_id no activated video route offers. Copy compatible values unchanged; no user input is needed for these internal identifiers."
        ]
    }
}
