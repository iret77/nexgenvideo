import Foundation
import NexGenEngine

enum PipelineArtifactWriteContract {
    static let measuredAnalysisSchemaVersion = "analysis/v2"

    static var analysisInterpretationSchema: [String: Any] { object(
        [
            "project_dir": projectDir,
            "tempo_multiplier": number,
            "section_labels": array(object(
                [
                    "index": integer,
                    "label": string,
                    "confidence": confidence,
                    "note": string,
                ],
                required: ["index", "label", "confidence"]
            ), minimum: 1),
            "anomalies": array(object(
                [
                    "kind": string,
                    "time": number,
                    "detail": string,
                ],
                required: ["kind", "detail"]
            )),
            "overall_character": string,
        ],
        required: [
            "tempo_multiplier",
            "section_labels",
            "anomalies",
            "overall_character",
        ]
    ) }

    static var productionDesignSchema: [String: Any] { object(
        [
            "project_dir": projectDir,
            "visual_medium": enumeration(VisualMedium.allCases.map(\.rawValue)),
            "visual_medium_notes": string,
            "refs": array(object(
                [
                    "path": string,
                    "note": string,
                ],
                required: ["path"]
            )),
            "color_script": keyValueArray(key: "section", value: "description"),
            "lighting_anchor": string,
            "notes": string,
        ],
        required: ["visual_medium", "refs", "color_script"]
    ) }

    static var treatmentSchema: [String: Any] { object(
        [
            "project_dir": projectDir,
            "origin": enumeration(TreatmentOrigin.allCases.map(\.rawValue)),
            "summary_oneline": string,
            "title": string,
            "notes": string,
            "body_markdown": string,
        ],
        required: ["origin", "summary_oneline", "body_markdown"]
    ) }

    static var storyboardSchema: [String: Any] { object(
        [
            "project_dir": projectDir,
            "origin": enumeration([
                "agent_proposal",
                "agent_revision",
                "user_supplied",
                "user_revision",
            ]),
            "summary_oneline": string,
            "notes": string,
            "sections": array(storyboardSection),
        ],
        required: ["origin", "summary_oneline", "sections"]
    ) }

    static var bibleSchema: [String: Any] { object(
        [
            "project_dir": projectDir,
            "look": lookGuide,
            "characters": array(character),
            "ensembles": array(ensemble),
            "props": array(prop),
            "locations": array(location),
            "notes": string,
        ],
        required: ["look", "characters", "ensembles", "props", "locations"]
    ) }

    static var shotlistSchema: [String: Any] { object(
        [
            "project_dir": projectDir,
            "shots": array(shot, minimum: 1),
            "notes": string,
        ],
        required: ["shots"]
    ) }

    private static var string: [String: Any] { ["type": "string"] }
    private static var nonEmptyString: [String: Any] {
        ["type": "string", "minLength": 1, "pattern": #"\S"#]
    }
    private static var setAnchorString: [String: Any] {
        [
            "type": "string",
            "minLength": 1,
            "pattern": #"^(?!\s*(?:(?:[Ss][Cc][Rr][Ee][Ee][Nn]|[Cc][Aa][Mm][Ee][Rr][Aa]|[Ff][Rr][Aa][Mm][Ee])[\s_-]*)?(?:[Ll][Ee][Ff][Tt]|[Rr][Ii][Gg][Hh][Tt]|[Cc][Ee][Nn][Tt](?:[Ee][Rr]|[Rr][Ee]))\s*$).*\S.*$"#,
        ]
    }
    private static var number: [String: Any] { ["type": "number"] }
    private static var integer: [String: Any] { ["type": "integer"] }
    private static var boolean: [String: Any] { ["type": "boolean"] }
    private static var confidence: [String: Any] {
        [
            "type": "number",
            "minimum": 0,
            "maximum": 1,
        ]
    }
    private static var projectDir: [String: Any] {
        [
            "type": "string",
            "description": "The project's pipeline data root. Omit to use the open project.",
        ]
    }

    private static var storyboardSection: [String: Any] { object(
        [
            "id": string,
            "label": string,
            "time_start": number,
            "time_end": number,
            "energy": enumeration(["low", "mid", "high", "drop"]),
            "function": enumeration(["aufbau", "refrain", "kontrast", "aufloesung"]),
            "pattern_override": string,
            "steps": array(storyboardStep, minimum: 4, maximum: 12),
        ],
        required: [
            "id",
            "label",
            "time_start",
            "time_end",
            "energy",
            "function",
            "steps",
        ]
    ) }

    private static var storyboardStep: [String: Any] {
        [
            "anyOf": SourceMode.allCases.map {
                storyboardStepVariant(sourceMode: $0)
            },
        ]
    }

    private static func storyboardStepVariant(
        sourceMode: SourceMode
    ) -> [String: Any] {
        var properties = storyboardStepProperties
        properties["source_mode"] = enumeration([sourceMode.rawValue])
        properties["character_blocking"] = array(storyboardBlocking(
            requiresSetAnchor: sourceMode == .generated
        ))
        return object(properties, required: storyboardStepRequired)
    }

    private static var storyboardStepProperties: [String: [String: Any]] {
        [
            "id": string,
            "function": enumeration(StepFunction.allCases.map(\.rawValue)),
            "subject": string,
            "camera": string,
            "setting_hint": string,
            "location_view_request": string,
            "character_view_request": keyValueArray(key: "character", value: "view"),
            "prop_request": stringArray,
            "framing": enumeration(Framing.allCases.map(\.rawValue)),
            "visible_zones": stringArray,
            "zone_introduces": stringArray,
            "camera_setup": cameraSetup,
            "character_blocking": array(storyboardBlocking(requiresSetAnchor: false)),
            "notes": string,
        ]
    }

    private static var storyboardStepRequired: [String] {
        [
            "id",
            "function",
            "source_mode",
            "subject",
            "camera",
            "setting_hint",
            "location_view_request",
            "character_view_request",
            "prop_request",
            "framing",
            "visible_zones",
            "zone_introduces",
            "camera_setup",
            "character_blocking",
        ]
    }

    private static func storyboardBlocking(
        requiresSetAnchor: Bool
    ) -> [String: Any] {
        let properties = [
            "character_ref": string,
            "position": string,
            "pose": string,
            "gaze": string,
            "relation_to_set": requiresSetAnchor ? nonEmptyString : string,
            "set_anchor": requiresSetAnchor ? setAnchorString : nonEmptyString,
        ]
        var required = [
            "character_ref", "position", "pose", "gaze", "relation_to_set",
        ]
        if requiresSetAnchor { required.append("set_anchor") }
        return object(properties, required: required)
    }

    private static var lookGuide: [String: Any] {
        object([
            "style": string,
            "palette": string,
            "lighting": string,
            "lens": string,
            "film_stock": string,
            "grain": string,
            "motion_style": string,
            "additional": string,
            "lighting_anchor": string,
        ])
    }

    private static var character: [String: Any] {
        object(
            entityProperties,
            required: entityRequired
        )
    }

    private static var ensemble: [String: Any] { object(
        entityProperties.merging([
            "member_count": integer,
            "members_description": string,
        ]) { _, new in new },
        required: entityRequired + ["member_count", "members_description"]
    ) }

    private static var prop: [String: Any] {
        object(
            entityProperties,
            required: entityRequired
        )
    }

    private static var location: [String: Any] { object(
        entityProperties.merging([
            "view_purpose": keyValueArray(key: "view", value: "purpose"),
            "floorplan": string,
            "zones": array(zone),
            "proportion_anchor_shot": string,
            "scene3d": scene3d,
        ]) { _, new in new },
        required: entityRequired + ["view_purpose", "zones", "scene3d"]
    ) }

    private static var entityProperties: [String: [String: Any]] {
        [
            "id": string,
            "name": string,
            "visual_prompt": string,
            "attributes": keyValueArray(key: "key", value: "value"),
            "hard_recognition_trait": string,
            "reference_images": stringArray,
            "sheets": keyValueArray(key: "view", value: "path"),
        ]
    }

    private static let entityRequired = [
        "id",
        "name",
        "visual_prompt",
        "attributes",
        "hard_recognition_trait",
        "reference_images",
        "sheets",
    ]

    private static var zone: [String: Any] { object(
        [
            "id": string,
            "description": string,
            "status": enumeration(ZoneStatus.allCases.map(\.rawValue)),
            "bible_assets": stringArray,
            "established_by_shot": string,
        ],
        required: ["id", "description", "status", "bible_assets"]
    ) }

    private static var scene3d: [String: Any] { object(
        [
            "panorama": string,
            "provider": string,
            "povs": array(object(
                [
                    "name": string,
                    "yaw": number,
                    "pitch": number,
                    "fov": number,
                ],
                required: ["name", "yaw", "pitch", "fov"]
            )),
        ],
        required: ["panorama", "provider", "povs"]
    ) }

    private static var shot: [String: Any] {
        [
            "anyOf": [
                shotVariant(sourceMode: .generated, requiresProductionPlan: true),
                shotVariant(sourceMode: .aiEnhanced, requiresProductionPlan: true),
                shotVariant(sourceMode: .imported, requiresProductionPlan: false),
            ],
        ]
    }

    private static func shotVariant(
        sourceMode: SourceMode,
        requiresProductionPlan: Bool
    ) -> [String: Any] {
        var properties = shotProperties
        properties["source_mode"] = enumeration([sourceMode.rawValue])
        properties["character_blocking"] = array(characterBlocking(
            requiresSetAnchor: sourceMode == .generated
        ))
        var required = shotRequired
        if requiresProductionPlan {
            properties["production_plan"] = productionPlan
            required.append("production_plan")
        }
        return object(properties, required: required)
    }

    private static var shotProperties: [String: [String: Any]] {
        [
            "id": string,
            "section": string,
            "time_start": number,
            "time_end": number,
            "duration_s": number,
            "type": enumeration(ShotType.allCases.map(\.rawValue)),
            "description": string,
            "visual_prompt": string,
            "motion": string,
            "mood": string,
            "lyrics_excerpt": string,
            "character_refs": stringArray,
            "character_views": keyValueArray(key: "character", value: "view"),
            "location_ref": string,
            "location_view": string,
            "model_suggestion": enumeration(ModelSuggestion.allCases.map(\.rawValue)),
            "keyframe_strategy": enumeration(KeyframeStrategy.allCases.map(\.rawValue)),
            "framing": enumeration(Framing.allCases.map(\.rawValue)),
            "visible_zones": stringArray,
            "zone_introduces": stringArray,
            "camera_setup": cameraSetup,
            "character_blocking": array(characterBlocking(requiresSetAnchor: false)),
            "prop_refs": stringArray,
            "prop_views": keyValueArray(key: "prop", value: "view"),
            "camera_id": string,
            "camera_label": string,
            "redo": boolean,
            "scene_video_provider": enumeration(SceneVideoProvider.allCases.map(\.rawValue)),
            "seedance_input_mode": enumeration(SeedanceInputMode.allCases.map(\.rawValue)),
            "reference_image_refs": stringArray,
            "chain_with_previous_end": boolean,
            "transition_in": enumeration(TransitionType.allCases.map(\.rawValue)),
            "transition_out": enumeration(TransitionType.allCases.map(\.rawValue)),
            "notes": string,
            "source_path": string,
        ]
    }

    private static var shotRequired: [String] {
        [
            "id",
            "time_start",
            "time_end",
            "duration_s",
            "type",
            "source_mode",
            "description",
            "visual_prompt",
            "mood",
            "character_refs",
            "character_views",
            "keyframe_strategy",
            "visible_zones",
            "zone_introduces",
            "character_blocking",
            "prop_refs",
            "prop_views",
            "redo",
            "scene_video_provider",
            "seedance_input_mode",
            "reference_image_refs",
            "chain_with_previous_end",
            "transition_in",
            "transition_out",
        ]
    }

    private static var productionPlan: [String: Any] { object(
        [
            "primary_action": string,
            "camera_movement": enumeration(CameraMovement.allCases.map(\.rawValue)),
            "camera_movement_detail": string,
            "narrative_beat": enumeration(NarrativeBeat.allCases.map(\.rawValue)),
            "renderability": enumeration(RenderabilityRating.allCases.map(\.rawValue)),
            "risks": array(enumeration(RenderabilityRisk.allCases.map(\.rawValue))),
            "rescue_cut": string,
            "match_action_cue": string,
            "continuity_locks": stringArray,
        ],
        required: [
            "primary_action",
            "camera_movement",
            "renderability",
            "risks",
            "continuity_locks",
        ]
    ) }

    private static var cameraSetup: [String: Any] { object(
        [
            "height": enumeration(CameraHeight.allCases.map(\.rawValue)),
            "angle": enumeration(CameraAngle.allCases.map(\.rawValue)),
            "lens_hint": enumeration(LensHint.allCases.map(\.rawValue)),
            "note": string,
        ],
        required: ["height", "angle", "lens_hint"]
    ) }

    private static func characterBlocking(
        requiresSetAnchor: Bool
    ) -> [String: Any] {
        let properties = [
            "character_ref": string,
            "position": string,
            "pose": string,
            "gaze": string,
            "relation_to_set": requiresSetAnchor ? nonEmptyString : string,
            "set_anchor": requiresSetAnchor ? setAnchorString : nonEmptyString,
        ]
        var required = [
            "character_ref", "position", "pose", "gaze", "relation_to_set",
        ]
        if requiresSetAnchor { required.append("set_anchor") }
        return object(properties, required: required)
    }

    private static var stringArray: [String: Any] {
        ["type": "array", "items": string]
    }

    private static func enumeration(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private static func keyValueArray(key: String, value: String) -> [String: Any] {
        array(object(
            [
                key: string,
                value: string,
            ],
            required: [key, value]
        ))
    }

    private static func array(
        _ items: [String: Any],
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "array",
            "items": items,
        ]
        if let minimum {
            schema["minItems"] = minimum
        }
        if let maximum {
            schema["maxItems"] = maximum
        }
        return schema
    }

    private static func object(
        _ properties: [String: [String: Any]],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }
}
