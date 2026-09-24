import Foundation
import NexGenEngine

enum AffectEvidenceWriteContract {
    static var schema: [String: Any] {
        let weighted: [String: Any] = [
            "type": "array", "items": object([
                "tag": ["type": "string", "enum": AffectTagVocabulary.all],
                "weight": ["type": "number", "exclusiveMinimum": 0],
            ], required: ["tag", "weight"]),
        ]
        let evidenceWeighted: [String: Any] = [
            "type": "array", "items": object([
                "value": ["type": "string", "enum": AffectTagVocabulary.all],
                "weight": ["type": "number", "exclusiveMinimum": 0],
            ], required: ["value", "weight"]),
        ]
        let text: [String: Any] = ["type": "string", "minLength": 1]
        let confidence: [String: Any] = ["type": "number", "minimum": 0, "maximum": 0.7]
        let signals: [String: Any] = ["type": "array", "uniqueItems": true, "items": ["type": "string", "enum": MusicAffectEvidenceV1.signalNames]]
        let section = object([
            "index": ["type": "integer", "description": "Exact approved analysis section index. Never invent timing."],
            "detected": evidenceWeighted,
            "confidence": confidence,
            "support": signals,
            "conflicts": signals,
            "rationale": text,
            "harmony": ["type": "string", "minLength": 1, "description": "Interpret progression, change rate, tension/resolution and any suspected modulation as inference. State missing/uncertain harmony explicitly. No major=happy or minor=sad rule."],
            "uncertainty": text,
            "visual_direction": ["type": "string", "minLength": 1, "description": "Concrete creative choice for this section. Begin with the exact effective desired affect tags followed by ': '. With no override use this section's detected tags; empty means 'undetermined: '. User override wins."],
            "abstention_reason": text,
        ], required: ["index", "detected", "confidence", "support", "conflicts", "rationale", "harmony", "uncertainty", "visual_direction"])
        return object([
            "detected": weighted,
            "override": weighted,
            "override_action": ["type": "string", "enum": ["preserve", "set", "clear"], "description": "Default preserve. Set/clear only on an explicit user choice; setting requires override and override_reason."],
            "override_reason": text,
            "rationale": text,
            "basis": ["type": "string", "enum": ["inferred"]],
            "harmonic_evidence": object([
                "schema": ["type": "string", "enum": [MusicAffectEvidenceV1.schema]],
                "summary": text,
                "confidence": confidence,
                "sections": ["type": "array", "minItems": 1, "items": section],
            ], required: ["schema", "summary", "confidence", "sections"]),
            "project_dir": ["type": "string"],
        ], required: ["detected", "rationale", "harmonic_evidence"])
    }

    private static func object(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
    }
}
