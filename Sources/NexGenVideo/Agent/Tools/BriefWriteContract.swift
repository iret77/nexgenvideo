import Foundation
import NexGenEngine

/// The agent-facing field contract for the `write_brief` tool (#247). One ordered list is the single
/// source that drives BOTH the tool's input schema AND its drift test — enum options are read from the
/// engine `Brief` enums' `.allCases`, never hand-typed, so the schema cannot drift from the type.
///
/// Server-owned fields (`schema`, `project`, `generated`, `generator`) are deliberately ABSENT here:
/// the executor injects them, and their omission from `allowedKeys` makes the agent supplying one a
/// rejected unknown key.
enum BriefWriteContract {

    enum Kind {
        case string
        case bool
        case double
        case stringArray
        /// Options come from `EnumType.allCases.map(\.rawValue)` — never a literal list.
        case enumField(options: [String])
        case enumArray(options: [String])

        var typeWord: String {
            switch self {
            case .string: return "a string"
            case .bool: return "a boolean"
            case .double: return "a number"
            case .stringArray: return "an array of strings"
            case .enumField, .enumArray: return "one of the allowed values"
            }
        }

        var options: [String]? {
            switch self {
            case .enumField(let o), .enumArray(let o): return o
            default: return nil
            }
        }
    }

    struct Field {
        let key: String
        let kind: Kind
        let required: Bool
        let description: String

        var enumOptions: [String]? { kind.options }

        var schemaProperty: [String: Any] {
            switch kind {
            case .string:
                return ["type": "string", "description": description]
            case .bool:
                return ["type": "boolean", "description": description]
            case .double:
                return ["type": "number", "description": description]
            case .stringArray:
                return ["type": "array", "items": ["type": "string"], "description": description]
            case .enumField(let options):
                return ["type": "string", "enum": options, "description": description]
            case .enumArray(let options):
                return ["type": "array", "items": ["type": "string", "enum": options], "description": description]
            }
        }
    }

    /// Modes a brief may NOT carry, with the reason. `Brief.projectMode` is a plain `String` (the
    /// engine's `Mode` is generic and packs use subsets), so without this the agent could persist
    /// `phrase` — which `shotlist.md` documents as deferred and tells the agent to fall back from — or
    /// a plain typo, and nothing would reject it. Enforcing it here is the point of the tool: the
    /// solution space is constrained by the contract, not by doc discipline.
    private static let modesUnsupportedInBrief: Set<Mode> = [
        .phrase,    // needs per-line forced alignment the analysis doesn't produce yet
        .generic,   // engine placeholder (#99), not a musicvideo cut mode
    ]

    /// Derived, never hand-listed: a new `Mode` case shows up automatically unless it is explicitly
    /// excluded above.
    static let briefProjectModes: [String] =
        Mode.allCases.filter { !modesUnsupportedInBrief.contains($0) }.map(\.rawValue)

    /// Ordered agent-facing fields. Wire keys match `Brief.CodingKeys`; enum options come from
    /// `.allCases`. `required` marks the fields the `Brief` decoder has NO default for.
    static let fields: [Field] = [
        Field(key: "mission", kind: .enumField(options: Mission.allCases.map(\.rawValue)),
              required: true, description: "Distribution intent. Use 'other' + mission_other for anything unlisted."),
        Field(key: "mission_other", kind: .string, required: false,
              description: "Free text when mission is 'other'."),
        Field(key: "target_platform", kind: .string, required: true,
              description: "Where it ships (YouTube / TikTok / IG / Vimeo / festival / …)."),
        Field(key: "target_audience", kind: .string, required: false,
              description: "Optional audience note."),
        Field(key: "aspect_ratio", kind: .enumField(options: AspectRatio.allCases.map(\.rawValue)),
              required: true, description: "Output aspect ratio. Use 'other' + aspect_ratio_other for unlisted."),
        Field(key: "aspect_ratio_other", kind: .string, required: false,
              description: "Free text when aspect_ratio is 'other'."),
        Field(key: "length_mode", kind: .string, required: false,
              description: "Full song or an excerpt (default 'full_song')."),
        Field(key: "project_mode", kind: .enumField(options: briefProjectModes),
              required: true, description: "Cut mode. 'phrase' is deliberately not offered — it needs per-line forced alignment the analysis does not produce yet."),
        Field(key: "model_preference", kind: .enumField(options: ModelPreference.allCases.map(\.rawValue)),
              required: false, description: "Preferred video model, or 'per_shot'. Defer to the shotlist phase if unknown."),
        Field(key: "model_preference_other", kind: .string, required: false,
              description: "Free text when model_preference is 'other'."),
        Field(key: "frame_image_model", kind: .enumField(options: FrameImageModel.allCases.map(\.rawValue)),
              required: false, description: "Image model for stills/bible sheets. Resolve against the host's registered models."),
        Field(key: "frame_image_model_other", kind: .string, required: false,
              description: "Free text when frame_image_model is 'other'."),
        Field(key: "bible_image_model", kind: .enumField(options: FrameImageModel.allCases.map(\.rawValue)),
              required: false, description: "High-consistency model for bible sheets (hybrid routing)."),
        Field(key: "composite_image_model", kind: .enumField(options: FrameImageModel.allCases.map(\.rawValue)),
              required: false, description: "Layout/text-strong model for shot composites (hybrid routing)."),
        Field(key: "budget_eur", kind: .double, required: false,
              description: "Planning budget in EUR (default 50). Must be > 0."),
        Field(key: "budget_stop_eur", kind: .double, required: false,
              description: "Optional hard spending stop in EUR (must be > 0). Omit for no hard stop."),
        Field(key: "concept_type", kind: .enumField(options: ConceptType.allCases.map(\.rawValue)),
              required: true, description: "Concept type. Use 'other' + concept_type_other for unlisted."),
        Field(key: "concept_type_other", kind: .string, required: false,
              description: "Free text when concept_type is 'other'."),
        Field(key: "visual_medium", kind: .enumField(options: VisualMedium.allCases.map(\.rawValue)),
              required: true, description: "Rendering register. Everything except live_action_realistic requires visual_medium_notes."),
        Field(key: "visual_medium_other", kind: .string, required: false,
              description: "Free text when visual_medium is 'other'."),
        Field(key: "visual_medium_notes", kind: .string, required: false,
              description: "Concrete style sentence. REQUIRED for every visual_medium except live_action_realistic."),
        Field(key: "tone", kind: .enumArray(options: ToneTag.allCases.map(\.rawValue)),
              required: false, description: "Tone tags (multi-select)."),
        Field(key: "tone_other", kind: .string, required: false,
              description: "Free text for tones outside the vocabulary."),
        Field(key: "style_references", kind: .stringArray, required: false,
              description: "Concrete visual references (videos, films, directors)."),
        Field(key: "figures", kind: .enumField(options: FigurePresence.allCases.map(\.rawValue)),
              required: true, description: "Who is on screen. Use 'other' + figures_other for unlisted."),
        Field(key: "figures_other", kind: .string, required: false,
              description: "Free text when figures is 'other'."),
        Field(key: "figure_count_hint", kind: .string, required: false,
              description: "Optional count hint."),
        Field(key: "lyrics_integration", kind: .enumField(options: LyricsIntegration.allCases.map(\.rawValue)),
              required: true, description: "How lyrics map to visuals. Use 'other' + lyrics_integration_other for unlisted."),
        Field(key: "lyrics_integration_other", kind: .string, required: false,
              description: "Free text when lyrics_integration is 'other'."),
        Field(key: "enable_chord_analysis", kind: .bool, required: false,
              description: "Whether downstream phases consume chords (default false)."),
        Field(key: "stems_provider", kind: .enumField(options: StemsProvider.allCases.map(\.rawValue)),
              required: false, description: "Stem-separation provider that ran (default demucs)."),
        Field(key: "final_resolution", kind: .enumField(options: VideoResolution.allCases.map(\.rawValue)),
              required: false, description: "Final render resolution (default 1080p)."),
        Field(key: "preview_mode", kind: .enumField(options: PreviewMode.allCases.map(\.rawValue)),
              required: false, description: "Preview-pass strategy (default skip)."),
        Field(key: "cut_handles_mode", kind: .enumField(options: CutHandlesMode.allCases.map(\.rawValue)),
              required: false, description: "Cut-handles override (default with_overlap)."),
        Field(key: "director_pattern", kind: .string, required: false,
              description: "Chosen director pattern id (optional)."),
        Field(key: "allow_genre_cross_patterns", kind: .bool, required: false,
              description: "Allow patterns outside the song's genre (default false)."),
        Field(key: "allow_text_overlays", kind: .bool, required: false,
              description: "Allow rendered text overlays / title cards (default false)."),
        Field(key: "notes", kind: .string, required: false,
              description: "Free notes."),
    ]

    static let requiredKeys: [String] = fields.filter(\.required).map(\.key)

    static let allowedKeys: Set<String> = Set(fields.map(\.key))

    static func field(_ key: String) -> Field? {
        fields.first { $0.key == key }
    }
}
