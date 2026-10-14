import Foundation
import NexGenEngine

enum PipelineExecutionIdentifierContract {
    static let pattern = #"^[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)+$"#

    static func schema(_ description: String) -> [String: Any] {
        ["type": "string", "minLength": 1, "pattern": pattern, "description": description]
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
            "extension_rule": "Namespaced pack-specific roles are allowed; preserve their declared semantics. Never invent a role or substitute an entity kind for a job ID.",
            "capability_discovery": "list_models.production_routes exposes the activated offerings with their actual input_slots and mode_ids. Copy compatible values unchanged; no user input is needed for these internal identifiers."
        ]
    }
}
