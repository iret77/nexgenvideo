import Foundation

/// Structured input for the provider-specific prompt builders. Port of
/// `render/prompt/builder.py::PromptPayload` (the dataclass). All fields carry
/// the same defaults as the Python dataclass; the builders formulate the
/// provider prompt from these fields.
public struct PromptPayload: Sendable, Equatable {
    /// WHAT — subject(s) plus concrete pose and vector.
    public var subject: String
    /// WHERE — location detail. Empty for clean-studio sheets.
    public var setting: String
    /// HOW — distance/frame, composition.
    public var composition: String
    /// Camera position AND movement across the shot duration.
    public var camera: String
    /// Style vocabulary, 1:1 from brief/look.
    public var style: String
    /// Light description.
    public var light: String
    /// Negatives — sparingly, style-excludes only.
    public var negatives: [String]
    /// Sheet view key. When set → sheet mode, otherwise frame mode.
    public var sheetView: String
    /// True for keyframe_strategy=start/start_end subject pose (t=0).
    public var isStartFrame: Bool
    /// Video-specific (Seedance/Veo).
    public var durationS: Double?
    public var aspectRatio: String
    public var nShots: Int
    /// Multi-ref hints — plain-text tags per reference image, in exact order of
    /// the reference-image array.
    public var multiRefHints: [String]
    /// Ledger directives (Shot + Bible refs + look/film). Locked directives MUST
    /// appear here — the compliance lint checks the finished prompt against them.
    public var directives: [String]
    /// Deterministic temporal structure for a handled shot (#213): a held beat of micro-motion before
    /// the action and/or a held pose after, so the model renders the cut handles as content instead of
    /// spreading the action across the gross duration. Empty for a plain shot.
    public var temporalStructure: String

    public init(
        subject: String,
        setting: String = "",
        composition: String = "",
        camera: String = "",
        style: String = "",
        light: String = "",
        negatives: [String] = [],
        sheetView: String = "",
        isStartFrame: Bool = false,
        durationS: Double? = nil,
        aspectRatio: String = "",
        nShots: Int = 1,
        multiRefHints: [String] = [],
        directives: [String] = [],
        temporalStructure: String = ""
    ) {
        self.subject = subject
        self.setting = setting
        self.composition = composition
        self.camera = camera
        self.style = style
        self.light = light
        self.negatives = negatives
        self.sheetView = sheetView
        self.isStartFrame = isStartFrame
        self.durationS = durationS
        self.aspectRatio = aspectRatio
        self.nShots = nShots
        self.multiRefHints = multiRefHints
        self.directives = directives
        self.temporalStructure = temporalStructure
    }
}

/// One reference for the fal-Seedance reference mode. Port of
/// `render/prompt/builder.py::ReferenceTag`. List order = order of the
/// `image_urls` list sent to fal (1-based: position 0 → `@Image1`).
public struct ReferenceTag: Sendable, Equatable {
    /// 'character' | 'location' | 'prop'.
    public var role: String
    public var bibleId: String
    public var hint: String

    public init(role: String, bibleId: String, hint: String) {
        self.role = role
        self.bibleId = bibleId
        self.hint = hint
    }
}
