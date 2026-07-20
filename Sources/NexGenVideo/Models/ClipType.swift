enum ClipType: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case image
    /// A TITLE clip — text rendered onto the canvas, with no source file behind it. NOT a text
    /// document: `.document` is the file-backed kind. They stay apart because the timeline reads
    /// `.text` as "has no source media", which is false for a script on disk.
    case text
    case lottie
    /// A text document in the library — story script, outline, notes. Source MATERIAL the pipeline
    /// reads; never placeable on the timeline (see `isPlaceable`).
    case document

    var sfSymbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .text: "textformat"
        case .lottie: "sparkles"
        case .document: "doc.text"
        }
    }

    var trackLabel: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .text: "Text"
        case .lottie: "Lottie"
        case .document: "Document"
        }
    }

    var trackLabelPrefix: String { String(trackLabel.prefix(1)) }

    var isVisual: Bool {
        self == .video || self == .image || self == .text || self == .lottie
    }

    /// Whether an asset of this kind can become a timeline clip at all. A document has no duration and
    /// nothing to render — placing one would produce a clip no player can draw, so the drop, insert and
    /// swap paths refuse it instead of creating a broken clip.
    var isPlaceable: Bool { self != .document }

    func isCompatible(with other: ClipType) -> Bool {
        guard isPlaceable, other.isPlaceable else { return false }
        return self == other || (self.isVisual && other.isVisual)
    }

    /// File extensions the app types as text documents (the `.document` kind) — the single source of
    /// truth for what "text" means, shared by the media importer and file-intake accept matching.
    static let documentExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "fountain"]

    init?(fileExtension ext: String) {
        switch ext {
        case "mov", "mp4", "m4v": self = .video
        case "mp3", "wav", "aac", "m4a", "aiff", "aif", "aifc", "flac": self = .audio
        case "png", "jpg", "jpeg", "tiff", "heic", "webp": self = .image
        case "json", "lottie": self = .lottie
        default:
            guard Self.documentExtensions.contains(ext) else { return nil }
            self = .document
        }
    }
}
