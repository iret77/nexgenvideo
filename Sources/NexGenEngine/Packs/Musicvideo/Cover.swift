import Foundation

/// Cover manifest per format (`cover/<format>.yaml`). Port of
/// `nexgen_pack_musicvideo/cover.py`.
///
/// Kept small — one artifact per format. Tracks only: paths, prompts used,
/// model, text-overlay parameters.
///
/// v0.10.20: multi-format support. One manifest per format (`square`,
/// `landscape`, `portrait`). Previously a single `cover.yaml` (deprecated,
/// the loader reads both).
public let coverSchemaVersion = "cover/v2"

/// Format key. Port of `cover.py::FormatKey`.
public enum CoverFormatKey: String, Codable, Sendable, CaseIterable {
    case square
    case landscape
    case portrait
}

/// Format -> aspect ratio + streaming-platform context. Port of
/// `cover.py::FORMAT_ASPECT`.
public let coverFormatAspect: [String: String] = [
    "square": "1:1",       // Spotify, Apple Music, Bandcamp, Instagram Post
    "landscape": "16:9",   // YouTube Thumbnail, Facebook Cover
    "portrait": "9:16",    // TikTok, Instagram Reels/Story, YouTube Shorts
]

/// Port of `cover.py::FORMAT_PLATFORM_HINT`.
public let coverFormatPlatformHint: [String: String] = [
    "square": "Streaming (Spotify/Apple Music/Bandcamp) and Instagram feed post",
    "landscape": "YouTube thumbnail, Facebook cover",
    "portrait": "TikTok, Instagram Reels/Story, YouTube Shorts",
]

/// Port of `cover.py::CoverClean`.
public struct CoverClean: Codable, Sendable, Equatable {
    /// Relative to `projects/<name>/`.
    public var path: String
    /// User-facing log note.
    public var prompt: String
    /// The actual prompt sent to the provider — for reproducibility + audit.
    public var providerPrompt: String
    public var modelId: String
    public var multiRefHints: [String]

    private enum CodingKeys: String, CodingKey {
        case path
        case prompt
        case providerPrompt = "provider_prompt"
        case modelId = "model_id"
        case multiRefHints = "multi_ref_hints"
    }

    public init(path: String, prompt: String, providerPrompt: String, modelId: String, multiRefHints: [String] = []) {
        self.path = path
        self.prompt = prompt
        self.providerPrompt = providerPrompt
        self.modelId = modelId
        self.multiRefHints = multiRefHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        prompt = try container.decode(String.self, forKey: .prompt)
        providerPrompt = try container.decode(String.self, forKey: .providerPrompt)
        modelId = try container.decode(String.self, forKey: .modelId)
        multiRefHints = try container.decodeIfPresent([String].self, forKey: .multiRefHints) ?? []
    }
}

/// Text-rendering path for the overlay. Port of `cover.py::TextOverlay.renderer`.
public enum CoverTextRenderer: String, Codable, Sendable, CaseIterable {
    /// Default: generates the image WITH text via GPT Image 2 (April 2026
    /// model). Preferred, because OpenAI's model renders text markedly more
    /// reliably than Nano Banana / Imagen (user directive 2026-05-31). Costs
    /// one provider call.
    case gptImage2 = "gpt_image_2"
    /// Deterministic overlay with Pillow on the clean cover. 100% correct,
    /// but the text looks bolted-on — no model-integrated design.
    case pillow
}

/// Port of `cover.py::TextOverlay.layout`.
public enum CoverTextLayout: String, Codable, Sendable, CaseIterable {
    case bottom
    case top
    case center
}

/// Port of `cover.py::TextOverlay.text_color`.
public enum CoverTextColor: String, Codable, Sendable, CaseIterable {
    case white
    case black
    /// Automatic light/dark depending on background brightness.
    case auto
}

/// Port of `cover.py::TextOverlay`.
public struct TextOverlay: Codable, Sendable, Equatable {
    public var artist: String
    public var title: String
    public var renderer: CoverTextRenderer
    public var layout: CoverTextLayout
    /// Only relevant for `renderer == .pillow`. The GPT-Image-2 path ignores it.
    public var fontFamily: String
    /// Only relevant for `renderer == .pillow`.
    public var textColor: CoverTextColor

    private enum CodingKeys: String, CodingKey {
        case artist
        case title
        case renderer
        case layout
        case fontFamily = "font_family"
        case textColor = "text_color"
    }

    public init(
        artist: String, title: String, renderer: CoverTextRenderer = .gptImage2, layout: CoverTextLayout = .bottom,
        fontFamily: String = "Helvetica", textColor: CoverTextColor = .auto
    ) {
        self.artist = artist
        self.title = title
        self.renderer = renderer
        self.layout = layout
        self.fontFamily = fontFamily
        self.textColor = textColor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artist = try container.decode(String.self, forKey: .artist)
        title = try container.decode(String.self, forKey: .title)
        renderer = try container.decodeIfPresent(CoverTextRenderer.self, forKey: .renderer) ?? .gptImage2
        layout = try container.decodeIfPresent(CoverTextLayout.self, forKey: .layout) ?? .bottom
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? "Helvetica"
        textColor = try container.decodeIfPresent(CoverTextColor.self, forKey: .textColor) ?? .auto
    }
}

/// Port of `cover.py::CoverText`.
public struct CoverText: Codable, Sendable, Equatable {
    /// Relative to `projects/<name>/`.
    public var path: String
    public var overlay: TextOverlay

    public init(path: String, overlay: TextOverlay) {
        self.path = path
        self.overlay = overlay
    }
}

/// Cover manifest per format. One format = one YAML under `cover/<format>.yaml`.
/// Port of `cover.py::CoverManifest`.
public struct CoverManifest: Codable, Sendable, Equatable {
    public var schema: String
    public var project: String
    public var format: CoverFormatKey
    public var generated: String
    public var clean: CoverClean?
    public var text: CoverText?

    private enum CodingKeys: String, CodingKey {
        case schema
        case project
        case format
        case generated
        case clean
        case text
    }

    public init(
        schema: String = coverSchemaVersion, project: String, format: CoverFormatKey = .square, generated: String,
        clean: CoverClean? = nil, text: CoverText? = nil
    ) {
        self.schema = schema
        self.project = project
        self.format = format
        self.generated = generated
        self.clean = clean
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(String.self, forKey: .schema) ?? coverSchemaVersion
        project = try container.decode(String.self, forKey: .project)
        format = try container.decodeIfPresent(CoverFormatKey.self, forKey: .format) ?? .square
        generated = try container.decode(String.self, forKey: .generated)
        clean = try container.decodeIfPresent(CoverClean.self, forKey: .clean)
        text = try container.decodeIfPresent(CoverText.self, forKey: .text)
    }
}

/// Cover-manifest load/save over a project directory. Port of `cover.py`'s
/// `_path` / `_legacy_path` / `load` / `save` module functions.
public enum Cover {
    private static func path(projectDir: URL, format: String = "square") -> URL {
        projectDir.appendingPathComponent("cover").appendingPathComponent("\(format).yaml")
    }

    private static func legacyPath(projectDir: URL) -> URL {
        projectDir.appendingPathComponent("cover").appendingPathComponent("cover.yaml")
    }

    /// Loads the manifest for `format`, falling back to the legacy
    /// `cover/cover.yaml` (v0.10.19, square-only) if the new-style path is
    /// absent. The legacy file predates the `format`/`schema` fields, but
    /// both default correctly on decode (`.square` / `coverSchemaVersion`),
    /// so no dict patching is needed before decoding. Port of `cover.py::load`.
    public static func load(projectDir: URL, format: String = "square") throws -> CoverManifest? {
        let p = path(projectDir: projectDir, format: format)
        if FileManager.default.fileExists(atPath: p.path) {
            let text = try String(contentsOf: p, encoding: .utf8)
            return try YAMLCoding.decode(CoverManifest.self, from: text)
        }
        // Fallback: old v0.10.19 path cover.yaml, for square only.
        if format == "square" {
            let legacy = legacyPath(projectDir: projectDir)
            if FileManager.default.fileExists(atPath: legacy.path) {
                let text = try String(contentsOf: legacy, encoding: .utf8)
                return try YAMLCoding.decode(CoverManifest.self, from: text)
            }
        }
        return nil
    }

    /// Port of `cover.py::save`.
    @discardableResult
    public static func save(projectDir: URL, manifest: CoverManifest) throws -> URL {
        let p = path(projectDir: projectDir, format: manifest.format.rawValue)
        try FileManager.default.createDirectory(
            at: p.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let yaml = try YAMLCoding.encode(manifest)
        try yaml.write(to: p, atomically: true, encoding: .utf8)
        return p
    }
}
