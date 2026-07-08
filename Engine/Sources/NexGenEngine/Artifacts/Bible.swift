import Foundation

/// Bible v5: Characters + Ensembles + Props + Locations + Look. Critical
/// consistency reference — every entity referenced by the shotlist must carry
/// at least one image anchor (`reference_images` or `sheets`), or renders
/// drift apart across shots. Port of `bible/schema.py`.
public let bibleSchemaVersion = "bible/v5"

/// Status of a named world-area within a Location, tracked so a generation
/// model never re-invents architecture/lighting for a zone another shot
/// already established. Port of `bible/schema.py::ZoneStatus`.
public enum ZoneStatus: String, Codable, Sendable, CaseIterable {
    case clean
    case dirty
    case undefined
    case safe
}

/// A named world-area of a Location (facade, back wall, left entrance, …).
/// Port of `bible/schema.py::Zone`.
public struct Zone: Codable, Sendable, Equatable {
    public var id: String
    public var description: String
    public var status: ZoneStatus
    public var bibleAssets: [String]
    public var establishedByShot: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case description
        case status
        case bibleAssets = "bible_assets"
        case establishedByShot = "established_by_shot"
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case idEmpty
    }

    public init(
        id: String, description: String, status: ZoneStatus, bibleAssets: [String] = [],
        establishedByShot: String? = nil
    ) throws {
        self.id = id
        self.description = description
        self.status = status
        self.bibleAssets = bibleAssets
        self.establishedByShot = establishedByShot
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        description = try container.decode(String.self, forKey: .description)
        status = try container.decode(ZoneStatus.self, forKey: .status)
        bibleAssets = try container.decodeIfPresent([String].self, forKey: .bibleAssets) ?? []
        establishedByShot = try container.decodeIfPresent(String.self, forKey: .establishedByShot)
        try validate()
    }

    /// Port of `Zone._id_slug`.
    public func validate() throws {
        guard !id.isEmpty else { throw ValidationError.idEmpty }
    }
}

/// Shared `_IdBase` field validation (id must be alnum/underscore,
/// visual_prompt non-empty after trim). Python models this via inheritance;
/// Swift has no struct inheritance, so each entity duplicates the `_IdBase`
/// stored properties and CodingKeys, and calls this helper from its own
/// `init(from:)`/validate to avoid re-deriving the checks four times.
public enum IdBaseValidationError: Swift.Error, Sendable, Equatable {
    case idNotAlnumUnderscore(String)
    case visualPromptEmpty
}

private func validateIdBase(id: String, visualPrompt: String) throws {
    let stripped = id.replacingOccurrences(of: "_", with: "")
    guard !id.isEmpty, !stripped.isEmpty, stripped.allSatisfy({ $0.isLetter || $0.isNumber }) else {
        throw IdBaseValidationError.idNotAlnumUnderscore(id)
    }
    guard !visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw IdBaseValidationError.visualPromptEmpty
    }
}

/// A person appearing in shots. Port of `bible/schema.py::Character`.
public struct Character: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var visualPrompt: String
    public var attributes: [String: String]
    public var hardRecognitionTrait: String
    public var referenceImages: [String]
    /// Keys: `front` | `side` | `back` | `expression_<tag>`.
    public var sheets: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case unknownSheetKey(String)
    }

    public init(
        id: String, name: String, visualPrompt: String, attributes: [String: String] = [:],
        hardRecognitionTrait: String = "", referenceImages: [String] = [], sheets: [String: String] = [:]
    ) throws {
        self.id = id
        self.name = name
        self.visualPrompt = visualPrompt
        self.attributes = attributes
        self.hardRecognitionTrait = hardRecognitionTrait
        self.referenceImages = referenceImages
        self.sheets = sheets
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        visualPrompt = try container.decode(String.self, forKey: .visualPrompt)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        hardRecognitionTrait =
            try container.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try container.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = try container.decodeIfPresent([String: String].self, forKey: .sheets) ?? [:]
        try validate()
    }

    /// Port of `_IdBase._id_slug` / `_visual_prompt_nonempty` / `Character._sheet_keys_known`.
    public func validate() throws {
        try validateIdBase(id: id, visualPrompt: visualPrompt)
        for key in sheets.keys {
            let known = key == "front" || key == "side" || key == "back" || key.hasPrefix("expression_")
            guard known else { throw ValidationError.unknownSheetKey(key) }
        }
    }

    public func hasAnchor() -> Bool {
        !referenceImages.isEmpty || !sheets.isEmpty
    }
}

/// A group with a shared appearance (school class, band, crowd) instead of n
/// pseudo-characters. Port of `bible/schema.py::Ensemble`.
public struct Ensemble: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var visualPrompt: String
    public var attributes: [String: String]
    public var hardRecognitionTrait: String
    public var memberCount: Int
    public var membersDescription: String
    public var referenceImages: [String]
    /// Free-form keys (e.g. `group_wide`) — Python's key validator is a no-op.
    public var sheets: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case memberCount = "member_count"
        case membersDescription = "members_description"
        case referenceImages = "reference_images"
        case sheets
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case memberCountNotPositive(Int)
    }

    public init(
        id: String, name: String, visualPrompt: String, attributes: [String: String] = [:],
        hardRecognitionTrait: String = "", memberCount: Int, membersDescription: String = "",
        referenceImages: [String] = [], sheets: [String: String] = [:]
    ) throws {
        self.id = id
        self.name = name
        self.visualPrompt = visualPrompt
        self.attributes = attributes
        self.hardRecognitionTrait = hardRecognitionTrait
        self.memberCount = memberCount
        self.membersDescription = membersDescription
        self.referenceImages = referenceImages
        self.sheets = sheets
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        visualPrompt = try container.decode(String.self, forKey: .visualPrompt)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        hardRecognitionTrait =
            try container.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        memberCount = try container.decode(Int.self, forKey: .memberCount)
        membersDescription =
            try container.decodeIfPresent(String.self, forKey: .membersDescription) ?? ""
        referenceImages = try container.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = try container.decodeIfPresent([String: String].self, forKey: .sheets) ?? [:]
        try validate()
    }

    /// Port of `_IdBase` validators + `Ensemble.member_count` `Field(gt=0)`.
    public func validate() throws {
        try validateIdBase(id: id, visualPrompt: visualPrompt)
        guard memberCount > 0 else { throw ValidationError.memberCountNotPositive(memberCount) }
    }

    public func hasAnchor() -> Bool {
        !referenceImages.isEmpty || !sheets.isEmpty
    }
}

/// A requisite (instrument, garment, vehicle, object). Port of `bible/schema.py::Prop`.
public struct Prop: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var visualPrompt: String
    public var attributes: [String: String]
    public var hardRecognitionTrait: String
    public var referenceImages: [String]
    /// Free-form keys (e.g. `closed`, `open`, `worn`) — no key restriction.
    public var sheets: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
    }

    public init(
        id: String, name: String, visualPrompt: String, attributes: [String: String] = [:],
        hardRecognitionTrait: String = "", referenceImages: [String] = [], sheets: [String: String] = [:]
    ) throws {
        self.id = id
        self.name = name
        self.visualPrompt = visualPrompt
        self.attributes = attributes
        self.hardRecognitionTrait = hardRecognitionTrait
        self.referenceImages = referenceImages
        self.sheets = sheets
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        visualPrompt = try container.decode(String.self, forKey: .visualPrompt)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        hardRecognitionTrait =
            try container.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try container.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = try container.decodeIfPresent([String: String].self, forKey: .sheets) ?? [:]
        try validate()
    }

    /// Port of `_IdBase._id_slug` / `_visual_prompt_nonempty`.
    public func validate() throws {
        try validateIdBase(id: id, visualPrompt: visualPrompt)
    }

    public func hasAnchor() -> Bool {
        !referenceImages.isEmpty || !sheets.isEmpty
    }
}

/// A shooting location, with optional multi-view sheets and zone tracking.
/// Port of `bible/schema.py::Location`.
public struct Location: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var visualPrompt: String
    public var attributes: [String: String]
    public var hardRecognitionTrait: String
    public var referenceImages: [String]
    /// Free-form keys, derived from storyboard needs (e.g. `wide`, `entrance`).
    public var sheets: [String: String]
    public var viewPurpose: [String: String]
    /// Deprecated since v0.5 (image models don't reliably read floorplans as
    /// a geometry anchor) — kept for backward compatibility, see `scene3d`.
    public var floorplan: String
    public var zones: [Zone]
    public var proportionAnchorShot: String?
    /// Scene3D (Marble + Re-Style) build metadata — free-form string map.
    public var scene3d: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case visualPrompt = "visual_prompt"
        case attributes
        case hardRecognitionTrait = "hard_recognition_trait"
        case referenceImages = "reference_images"
        case sheets
        case viewPurpose = "view_purpose"
        case floorplan
        case zones
        case proportionAnchorShot = "proportion_anchor_shot"
        case scene3d
    }

    public init(
        id: String, name: String, visualPrompt: String, attributes: [String: String] = [:],
        hardRecognitionTrait: String = "", referenceImages: [String] = [], sheets: [String: String] = [:],
        viewPurpose: [String: String] = [:], floorplan: String = "", zones: [Zone] = [],
        proportionAnchorShot: String? = nil, scene3d: [String: String] = [:]
    ) throws {
        self.id = id
        self.name = name
        self.visualPrompt = visualPrompt
        self.attributes = attributes
        self.hardRecognitionTrait = hardRecognitionTrait
        self.referenceImages = referenceImages
        self.sheets = sheets
        self.viewPurpose = viewPurpose
        self.floorplan = floorplan
        self.zones = zones
        self.proportionAnchorShot = proportionAnchorShot
        self.scene3d = scene3d
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        visualPrompt = try container.decode(String.self, forKey: .visualPrompt)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        hardRecognitionTrait =
            try container.decodeIfPresent(String.self, forKey: .hardRecognitionTrait) ?? ""
        referenceImages = try container.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
        sheets = try container.decodeIfPresent([String: String].self, forKey: .sheets) ?? [:]
        viewPurpose = try container.decodeIfPresent([String: String].self, forKey: .viewPurpose) ?? [:]
        floorplan = try container.decodeIfPresent(String.self, forKey: .floorplan) ?? ""
        zones = try container.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        proportionAnchorShot = try container.decodeIfPresent(String.self, forKey: .proportionAnchorShot)
        scene3d = try container.decodeIfPresent([String: String].self, forKey: .scene3d) ?? [:]
        try validate()
    }

    /// Port of `_IdBase._id_slug` / `_visual_prompt_nonempty`.
    public func validate() throws {
        try validateIdBase(id: id, visualPrompt: visualPrompt)
    }

    public func hasAnchor() -> Bool {
        !referenceImages.isEmpty || !sheets.isEmpty
    }
}

/// Global visual style guide for the project. Port of `bible/schema.py::LookGuide`.
public struct LookGuide: Codable, Sendable, Equatable {
    public var style: String
    public var palette: String
    public var lighting: String
    public var lens: String
    public var filmStock: String
    public var grain: String
    public var motionStyle: String
    public var additional: String
    public var lightingAnchor: String

    private enum CodingKeys: String, CodingKey {
        case style
        case palette
        case lighting
        case lens
        case filmStock = "film_stock"
        case grain
        case motionStyle = "motion_style"
        case additional
        case lightingAnchor = "lighting_anchor"
    }

    public init(
        style: String = "", palette: String = "", lighting: String = "", lens: String = "",
        filmStock: String = "", grain: String = "", motionStyle: String = "", additional: String = "",
        lightingAnchor: String = ""
    ) {
        self.style = style
        self.palette = palette
        self.lighting = lighting
        self.lens = lens
        self.filmStock = filmStock
        self.grain = grain
        self.motionStyle = motionStyle
        self.additional = additional
        self.lightingAnchor = lightingAnchor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        style = try container.decodeIfPresent(String.self, forKey: .style) ?? ""
        palette = try container.decodeIfPresent(String.self, forKey: .palette) ?? ""
        lighting = try container.decodeIfPresent(String.self, forKey: .lighting) ?? ""
        lens = try container.decodeIfPresent(String.self, forKey: .lens) ?? ""
        filmStock = try container.decodeIfPresent(String.self, forKey: .filmStock) ?? ""
        grain = try container.decodeIfPresent(String.self, forKey: .grain) ?? ""
        motionStyle = try container.decodeIfPresent(String.self, forKey: .motionStyle) ?? ""
        additional = try container.decodeIfPresent(String.self, forKey: .additional) ?? ""
        lightingAnchor = try container.decodeIfPresent(String.self, forKey: .lightingAnchor) ?? ""
    }
}

/// A visual entity found by `Bible.lookupId(_:)`. Models Python's
/// `Character | Ensemble | Prop | Location | None` union return as an enum,
/// since Swift has no anonymous union type.
public enum BibleEntity: Sendable, Equatable {
    case character(Character)
    case ensemble(Ensemble)
    case prop(Prop)
    case location(Location)
}

/// Bible (K5): the project's visual consistency reference, persisted as
/// `bible/bible.yaml`. Port of `bible/schema.py::Bible`.
public struct Bible: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    public var generated: String
    public var generator: String
    public var look: LookGuide
    public var characters: [Character]
    public var ensembles: [Ensemble]
    public var props: [Prop]
    public var locations: [Location]
    public var notes: String?

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case generated
        case generator
        case look
        case characters
        case ensembles
        case props
        case locations
        case notes
    }

    public enum ValidationError: Swift.Error, Sendable, Equatable {
        case unknownSchema(String)
        case idsNotGloballyUnique([String])
        case missingAnchors([String])
    }

    public init(
        schema: String = bibleSchemaVersion, project: String, generated: String, generator: String,
        look: LookGuide = LookGuide(), characters: [Character] = [], ensembles: [Ensemble] = [],
        props: [Prop] = [], locations: [Location] = [], notes: String? = nil
    ) throws {
        self.schema = schema
        self.project = project
        self.generated = generated
        self.generator = generator
        self.look = look
        self.characters = characters
        self.ensembles = ensembles
        self.props = props
        self.locations = locations
        self.notes = notes
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? bibleSchemaVersion
        project = try container.decode(String.self, forKey: .project)
        generated = try container.decode(String.self, forKey: .generated)
        generator = try container.decode(String.self, forKey: .generator)
        look = try container.decodeIfPresent(LookGuide.self, forKey: .look) ?? LookGuide()
        characters = try container.decodeIfPresent([Character].self, forKey: .characters) ?? []
        ensembles = try container.decodeIfPresent([Ensemble].self, forKey: .ensembles) ?? []
        props = try container.decodeIfPresent([Prop].self, forKey: .props) ?? []
        locations = try container.decodeIfPresent([Location].self, forKey: .locations) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        try validate()
    }

    /// Port of `Bible._schema_const`, `_ids_unique_globally`,
    /// `_every_visual_entity_has_anchor`.
    public func validate() throws {
        guard schema == bibleSchemaVersion || schema == "bible/v4" else {
            throw ValidationError.unknownSchema(schema)
        }

        let allIds = characters.map(\.id) + ensembles.map(\.id) + props.map(\.id) + locations.map(\.id)
        if Set(allIds).count != allIds.count {
            throw ValidationError.idsNotGloballyUnique(allIds)
        }

        // Props are exempt: soft/warning-only per the Python comment, not a hard-fail.
        var missing: [String] = []
        for c in characters where !c.hasAnchor() { missing.append("character '\(c.id)'") }
        for e in ensembles where !e.hasAnchor() { missing.append("ensemble '\(e.id)'") }
        for loc in locations where !loc.hasAnchor() { missing.append("location '\(loc.id)'") }
        if !missing.isEmpty {
            throw ValidationError.missingAnchors(missing)
        }
    }

    /// Port of `Bible.lookup_id`: searches characters, then ensembles, props,
    /// locations, in that order, returning the first id match.
    public func lookupId(_ ref: String) -> BibleEntity? {
        if let c = characters.first(where: { $0.id == ref }) { return .character(c) }
        if let e = ensembles.first(where: { $0.id == ref }) { return .ensemble(e) }
        if let p = props.first(where: { $0.id == ref }) { return .prop(p) }
        if let loc = locations.first(where: { $0.id == ref }) { return .location(loc) }
        return nil
    }
}

/// Loads `bible/bible.yaml` if present, else `nil` — mirrors Python's
/// `bible/schema.py::load`, which returns `Bible | None` rather than raising
/// on a missing file (unlike `YAMLArtifactStore.load`, which throws).
public func loadBible(dataRoot: URL) throws -> Bible? {
    let url = StudioLayout.url(StudioLayout.bibleFile, in: dataRoot)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try YAMLArtifactStore(dataRoot: dataRoot).load(Bible.self, at: StudioLayout.bibleFile)
}
