import Foundation

// Mirrors the engine's `Bible.model_dump(by_alias=True)` JSON (engine/nexgen_engine/bible/schema.py).
// Only `schema` is aliased there (from `schema_`); every other field keeps its Python name, so the
// CodingKeys below match the raw JSON keys. Decoding is defensive: missing keys fall back to sensible
// defaults and unknown extra keys are ignored, so a newer engine schema still loads read-only.

struct BibleData: Decodable, Sendable, Equatable {
    var schema: String
    var project: String
    var generated: String
    var generator: String
    var look: BibleLook
    var characters: [BibleCharacter]
    var ensembles: [BibleEnsemble]
    var props: [BibleProp]
    var locations: [BibleLocation]
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case schema, project, generated, generator, look
        case characters, ensembles, props, locations, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        generated = try c.decodeIfPresent(String.self, forKey: .generated) ?? ""
        generator = try c.decodeIfPresent(String.self, forKey: .generator) ?? ""
        look = try c.decodeIfPresent(BibleLook.self, forKey: .look) ?? BibleLook()
        characters = try c.decodeIfPresent([BibleCharacter].self, forKey: .characters) ?? []
        ensembles = try c.decodeIfPresent([BibleEnsemble].self, forKey: .ensembles) ?? []
        props = try c.decodeIfPresent([BibleProp].self, forKey: .props) ?? []
        locations = try c.decodeIfPresent([BibleLocation].self, forKey: .locations) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

struct BibleLook: Decodable, Sendable, Equatable {
    var style: String = ""
    var palette: String = ""
    var lighting: String = ""
    var lens: String = ""
    var filmStock: String = ""
    var grain: String = ""
    var motionStyle: String = ""
    var additional: String = ""

    enum CodingKeys: String, CodingKey {
        case style, palette, lighting, lens
        case filmStock = "film_stock"
        case grain
        case motionStyle = "motion_style"
        case additional
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? ""
        palette = try c.decodeIfPresent(String.self, forKey: .palette) ?? ""
        lighting = try c.decodeIfPresent(String.self, forKey: .lighting) ?? ""
        lens = try c.decodeIfPresent(String.self, forKey: .lens) ?? ""
        filmStock = try c.decodeIfPresent(String.self, forKey: .filmStock) ?? ""
        grain = try c.decodeIfPresent(String.self, forKey: .grain) ?? ""
        motionStyle = try c.decodeIfPresent(String.self, forKey: .motionStyle) ?? ""
        additional = try c.decodeIfPresent(String.self, forKey: .additional) ?? ""
    }

    /// Ordered label/value pairs for the non-empty fields, for a key/value render.
    var fields: [(label: String, value: String)] {
        [
            ("Style", style),
            ("Palette", palette),
            ("Lighting", lighting),
            ("Lens", lens),
            ("Film Stock", filmStock),
            ("Grain", grain),
            ("Motion", motionStyle),
            ("Additional", additional),
        ].filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isEmpty: Bool { fields.isEmpty }
}

/// Common shape shared by every Bible entity kind, so one card view renders all of them.
protocol BibleEntity: Sendable {
    var id: String { get }
    var name: String { get }
    var visualPrompt: String { get }
    var attributes: [BibleAttribute] { get }
    var hardRecognitionTrait: String { get }
    var referenceImages: [String] { get }
    var sheets: [BibleSheet] { get }
}

/// A single structured consistency attribute (key/value). Identifiable for stable ForEach.
struct BibleAttribute: Sendable, Equatable, Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

/// A reference-sheet entry: a label key plus a path relative to the project dir.
struct BibleSheet: Sendable, Equatable, Identifiable {
    let key: String
    let path: String
    var id: String { key }
}

// Attributes/sheets decode as unordered dicts in JSON; sort by key for a stable, deterministic render.
private func decodeAttributes(_ raw: [String: String]?) -> [BibleAttribute] {
    (raw ?? [:]).sorted { $0.key < $1.key }.map { BibleAttribute(key: $0.key, value: $0.value) }
}

private func decodeSheets(_ raw: [String: String]?) -> [BibleSheet] {
    (raw ?? [:]).sorted { $0.key < $1.key }.map { BibleSheet(key: $0.key, path: $0.value) }
}

struct BibleCharacter: Decodable, Sendable, Equatable, Identifiable, BibleEntity {
    var id: String
    var name: String
    var visualPrompt: String
    var attributes: [BibleAttribute]
    var hardRecognitionTrait: String
    var referenceImages: [String]
    var sheets: [BibleSheet]

    static func == (lhs: BibleCharacter, rhs: BibleCharacter) -> Bool { lhs.id == rhs.id }

    enum CodingKeys: String, CodingKey {
        case id, name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt) ?? ""
        attributes = decodeAttributes(try c.decodeIfPresent([String: String].self, forKey: .attributes))
        hardRecognitionTrait = try c.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try c.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = decodeSheets(try c.decodeIfPresent([String: String].self, forKey: .sheets))
    }
}

struct BibleEnsemble: Decodable, Sendable, Equatable, Identifiable, BibleEntity {
    var id: String
    var name: String
    var visualPrompt: String
    var attributes: [BibleAttribute]
    var hardRecognitionTrait: String
    var referenceImages: [String]
    var sheets: [BibleSheet]
    var memberCount: Int?
    var membersDescription: String

    static func == (lhs: BibleEnsemble, rhs: BibleEnsemble) -> Bool { lhs.id == rhs.id }

    enum CodingKeys: String, CodingKey {
        case id, name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
        case memberCount = "member_count"
        case membersDescription = "members_description"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt) ?? ""
        attributes = decodeAttributes(try c.decodeIfPresent([String: String].self, forKey: .attributes))
        hardRecognitionTrait = try c.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try c.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = decodeSheets(try c.decodeIfPresent([String: String].self, forKey: .sheets))
        memberCount = try c.decodeIfPresent(Int.self, forKey: .memberCount)
        membersDescription = try c.decodeIfPresent(String.self, forKey: .membersDescription) ?? ""
    }
}

struct BibleProp: Decodable, Sendable, Equatable, Identifiable, BibleEntity {
    var id: String
    var name: String
    var visualPrompt: String
    var attributes: [BibleAttribute]
    var hardRecognitionTrait: String
    var referenceImages: [String]
    var sheets: [BibleSheet]

    static func == (lhs: BibleProp, rhs: BibleProp) -> Bool { lhs.id == rhs.id }

    enum CodingKeys: String, CodingKey {
        case id, name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt) ?? ""
        attributes = decodeAttributes(try c.decodeIfPresent([String: String].self, forKey: .attributes))
        hardRecognitionTrait = try c.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try c.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = decodeSheets(try c.decodeIfPresent([String: String].self, forKey: .sheets))
    }
}

struct BibleLocation: Decodable, Sendable, Equatable, Identifiable, BibleEntity {
    var id: String
    var name: String
    var visualPrompt: String
    var attributes: [BibleAttribute]
    var hardRecognitionTrait: String
    var referenceImages: [String]
    var sheets: [BibleSheet]

    static func == (lhs: BibleLocation, rhs: BibleLocation) -> Bool { lhs.id == rhs.id }

    enum CodingKeys: String, CodingKey {
        case id, name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt) ?? ""
        attributes = decodeAttributes(try c.decodeIfPresent([String: String].self, forKey: .attributes))
        hardRecognitionTrait = try c.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try c.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = decodeSheets(try c.decodeIfPresent([String: String].self, forKey: .sheets))
    }
}
