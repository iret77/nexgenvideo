import Foundation
import NexGenEngine

// Mirrors the engine's `Shotlist.model_dump(by_alias=True, mode="json")` JSON
// (engine/nexgen_engine/shotlist/schema.py, via read.py "shotlist"). Only `schema` is aliased
// (from `schema_`); every other field keeps its Python snake_case name, so the CodingKeys below match
// the raw JSON keys. Enums (type, framing) serialize to their string values (e.g. "close-up",
// "wide"). Decoding is defensive — only the fields the panel needs are read; unknown keys are ignored,
// so a newer shot schema still loads read-only. The panel is a summary list, not a full shot editor.

struct ShotlistData: Decodable, Sendable, Equatable {
    var schema: String
    var project: String
    var mode: String
    var generated: String
    var shots: [ShotSummary]

    enum CodingKeys: String, CodingKey {
        case schema, project, mode, generated, shots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        generated = try c.decodeIfPresent(String.self, forKey: .generated) ?? ""
        shots = try c.decodeIfPresent([ShotSummary].self, forKey: .shots) ?? []
    }
}

/// A read-only, summary view of one shot — just what the cockpit list renders.
struct ShotSummary: Decodable, Sendable, Equatable, Identifiable {
    var id: String
    var section: String?
    var durationS: Double
    var type: String
    var sourceMode: String
    var description: String
    var visualPrompt: String
    var framing: String?
    var mood: String
    // Bible provenance: entity ids this shot uses (the object graph's shot↔entity edges).
    var characterRefs: [String]
    var locationRef: String?
    var propRefs: [String]

    enum CodingKeys: String, CodingKey {
        case id, section, type, description, framing, mood
        case sourceMode = "source_mode"
        case durationS = "duration_s"
        case visualPrompt = "visual_prompt"
        case characterRefs = "character_refs"
        case locationRef = "location_ref"
        case propRefs = "prop_refs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        section = try c.decodeIfPresent(String.self, forKey: .section)
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        sourceMode = try c.decodeIfPresent(String.self, forKey: .sourceMode) ?? "generated"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt) ?? ""
        framing = try c.decodeIfPresent(String.self, forKey: .framing)
        mood = try c.decodeIfPresent(String.self, forKey: .mood) ?? ""
        characterRefs = try c.decodeIfPresent([String].self, forKey: .characterRefs) ?? []
        locationRef = try c.decodeIfPresent(String.self, forKey: .locationRef)
        propRefs = try c.decodeIfPresent([String].self, forKey: .propRefs) ?? []
    }

    /// A one-line summary preferring the human description, then the visual prompt.
    var summaryText: String {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        return visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short chips rendered under each shot: type, framing, duration. Empty entries dropped.
    var chips: [String] {
        var out: [String] = []
        let t = type.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        if let f = framing?.trimmingCharacters(in: .whitespaces), !f.isEmpty { out.append(f) }
        if durationS > 0 { out.append(String(format: "%.1fs", durationS)) }
        return out
    }

    /// The parsed source mode, defaulting to generated for any unknown/absent raw value.
    var sourceModeTag: SourceModeTag { SourceModeTag(raw: sourceMode) }
}

/// App-side descriptor for a shot's source mode (hybrid production, issue #129): the SF Symbol,
/// short label, and the raw engine value shared by the shotlist panel badge, the mode filter, and
/// the shot inspector menu. Mirrors NexGenEngine's `SourceMode` snake_case raw values.
enum SourceModeTag: String, CaseIterable, Identifiable {
    case generated
    case liveAction = "live_action"
    case aiEnhanced = "ai_enhanced"

    var id: String { rawValue }

    init(raw: String) { self = SourceModeTag(rawValue: raw) ?? .generated }

    /// SF Symbol per mode: generated = sparkles, live = video, enhanced = wand.and.rays.
    var symbol: String {
        switch self {
        case .generated: "sparkles"
        case .liveAction: "video"
        case .aiEnhanced: "wand.and.rays"
        }
    }

    /// Compact tag label for the per-row badge.
    var label: String {
        switch self {
        case .generated: "Generated"
        case .liveAction: "Live"
        case .aiEnhanced: "Enhanced"
        }
    }

    /// The engine `SourceMode` this tag writes back (shared snake_case raw value).
    var engineMode: SourceMode { SourceMode(rawValue: rawValue) ?? .generated }
}
