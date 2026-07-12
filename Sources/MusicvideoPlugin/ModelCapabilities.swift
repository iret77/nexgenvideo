import Foundation
import NexGenEngine

/// Port of common/models.py ModelCapability + MODEL_CAPABILITIES + common/aspect.py resolver.
public struct ModelCapability: Sendable, Equatable {
    public let maxDurationS: Double
    public let supportedRatios: [String]
    public let maxCharactersInFrame: Int
    public let supportsKeyframeStart: Bool
    public let supportsKeyframeEnd: Bool
    public let supportsImageToVideo: Bool
    public let supportsReferenceMode: Bool
    public let maxReferenceImages: Int
    public let notes: String

    public init(
        maxDurationS: Double,
        supportedRatios: [String],
        maxCharactersInFrame: Int,
        supportsKeyframeStart: Bool,
        supportsKeyframeEnd: Bool,
        supportsImageToVideo: Bool,
        supportsReferenceMode: Bool = false,
        maxReferenceImages: Int = 0,
        notes: String = ""
    ) {
        self.maxDurationS = maxDurationS
        self.supportedRatios = supportedRatios
        self.maxCharactersInFrame = maxCharactersInFrame
        self.supportsKeyframeStart = supportsKeyframeStart
        self.supportsKeyframeEnd = supportsKeyframeEnd
        self.supportsImageToVideo = supportsImageToVideo
        self.supportsReferenceMode = supportsReferenceMode
        self.maxReferenceImages = maxReferenceImages
        self.notes = notes
    }
}

public enum ModelCapabilities {
    /// Faithful port of MODEL_CAPABILITIES — every model entry, exact values.
    public static let all: [String: ModelCapability] = [
        "gen3a_turbo": ModelCapability(
            maxDurationS: 10.0,
            supportedRatios: ["1280:720", "720:1280", "960:960", "1104:832", "832:1104"],
            maxCharactersInFrame: 2,
            supportsKeyframeStart: true,
            supportsKeyframeEnd: false,
            supportsImageToVideo: true,
            notes: "Günstig, schnell. Gut für Previews. Limits bei komplexen Szenen."
        ),
        "gen4.5": ModelCapability(
            maxDurationS: 10.0,
            supportedRatios: ["1280:720", "720:1280", "960:960", "1104:832", "832:1104"],
            maxCharactersInFrame: 3,
            supportsKeyframeStart: true,
            supportsKeyframeEnd: true,
            supportsImageToVideo: true,
            notes: "Beste Charakter-Konsistenz, bevorzugt bei Narrativ+Performance."
        ),
        "seedance2": ModelCapability(
            maxDurationS: 15.0,
            supportedRatios: [
                // 512er-Stufe
                "992:432", "864:496", "752:560", "640:640", "560:752", "496:864",
                // 720er-Stufe
                "1470:630", "1280:720", "1112:834", "960:960", "834:1112", "720:1280",
                // 1080er-Stufe
                "2206:946", "1920:1080", "1664:1248", "1440:1440", "1248:1664", "1080:1920",
            ],
            maxCharactersInFrame: 3,
            supportsKeyframeStart: true,
            supportsKeyframeEnd: true,
            supportsImageToVideo: true,
            notes: "Modi (Runway-API live 2026-05-31): References / Start-End frames / Text-to-Video. "
                + "Duration 4-15 s (Provider rundet kuerzere Shots auf 4 s auf, "
                + "Mehr-Sekunden werden berechnet). Output 480p/720p/1080p — supported_ratios "
                + "decken alle drei Aufloesungs-Stufen ab. Bis zu 9 Reference Images "
                + "(.jpg/.jpeg/.png/.webm, 300-6000 px, <30 MB). "
                + "max_characters_in_frame=3 ist eine Stabilitäts-Heuristik fürs Bild — "
                + "konsistente Darstellung aller Figuren im selben Frame degradiert ab 3+."
        ),
        "veo3": ModelCapability(
            maxDurationS: 8.0,
            supportedRatios: ["1280:720", "720:1280"],
            maxCharactersInFrame: 4,
            supportsKeyframeStart: false,
            supportsKeyframeEnd: false,
            supportsImageToVideo: false,
            notes: "Text-to-video only, keine Keyframes. Hohes Motion-Detail, teuer."
        ),
        "veo3.1_fast": ModelCapability(
            maxDurationS: 8.0,
            supportedRatios: ["1280:720", "720:1280"],
            maxCharactersInFrame: 3,
            supportsKeyframeStart: false,
            supportsKeyframeEnd: false,
            supportsImageToVideo: false,
            notes: "Schnellere, günstigere Veo3-Variante."
        ),
        "fal:bytedance/seedance-2.0": ModelCapability(
            maxDurationS: 15.0,
            supportedRatios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9"],
            maxCharactersInFrame: 4,
            supportsKeyframeStart: true,
            supportsKeyframeEnd: true,
            supportsImageToVideo: true,
            supportsReferenceMode: true,
            maxReferenceImages: 9,
            notes: "Seedance 2.0 Pro auf fal.ai. Drei Modi (mutually exclusive): "
                + "text-to-video, image-to-video (Keyframe first/last), "
                + "reference-to-video (bis 9 Bilder + 3 Videos + 3 Audio "
                + "per @image1-Mention). Resolutions 480p/720p/1080p, "
                + "Duration 4-15 s. Audio-Lip-Sync moeglich."
        ),
        "fal:bytedance/seedance-2.0/fast": ModelCapability(
            maxDurationS: 15.0,
            supportedRatios: ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9"],
            maxCharactersInFrame: 4,
            supportsKeyframeStart: true,
            supportsKeyframeEnd: true,
            supportsImageToVideo: true,
            supportsReferenceMode: true,
            maxReferenceImages: 9,
            notes: "Seedance 2.0 Fast — gleicher Feature-Set wie Pro, "
                + "guenstigere/schnellere Inferenz, leicht reduzierte Qualitaet. "
                + "Empfohlen fuer Previews."
        ),
    ]

    public static func capability(_ model: String) -> ModelCapability? { all[model] }
}

public enum AspectResolver {
    /// Port of ASPECT_TO_FLOAT — Brief-aspect strings to their W/H float.
    public static let aspectToFloat: [String: Double] = [
        "16:9": 16.0 / 9.0,
        "9:16": 9.0 / 16.0,
        "1:1": 1.0,
        "4:5": 4.0 / 5.0,
        "5:4": 5.0 / 4.0,
        "4:3": 4.0 / 3.0,
        "3:4": 3.0 / 4.0,
        "21:9": 21.0 / 9.0,
        "9:21": 9.0 / 21.0,
    ]

    /// Port of resolve_brief_aspect: the semantic aspect string for a brief, or
    /// nil if unresolvable (mirrors AspectUnresolvable). `aspectRatio` is the
    /// brief's `aspect_ratio` raw value ("16:9" … "9:21" or "other");
    /// `aspectOther` is the free-text `aspect_ratio_other`.
    public static func resolveBriefAspect(aspectRatio: String, aspectOther: String?) -> String? {
        if !aspectRatio.isEmpty && aspectRatio != "other" {
            return aspectRatio
        }
        return parseAspectFreeform(aspectOther ?? "")
    }

    /// Port of resolve_for_model: float-aware ratio match of a semantic aspect
    /// against a model's supported ratios. Returns the matching supported-ratio
    /// string (highest resolution wins), or nil on a real cap mismatch.
    public static func resolveForModel(
        _ aspect: String,
        supportedRatios: [String],
        tolerance: Double = 0.05
    ) -> String? {
        if supportedRatios.isEmpty { return nil }
        guard let targetFloat = aspectToFloat[aspect] ?? ratioStringToFloat(aspect) else { return nil }
        // (resolution, sourceIndex, ratio) — index keeps the sort stable so the
        // tie-break matches Python's stable sort byte-for-byte.
        var candidates: [(res: Int, idx: Int, ratio: String)] = []
        for (idx, s) in supportedRatios.enumerated() {
            if let (w, h) = ratioStringToDims(s) {
                if h == 0 { continue }
                let f = Double(w) / Double(h)
                if abs(f - targetFloat) <= tolerance {
                    candidates.append((w * h, idx, s))
                }
            } else {
                // e.g. a Google semantic string like "16:9" — float compare via
                // aspectToFloat; no pixel info, so lowest resolution priority.
                guard let f = aspectToFloat[s] ?? ratioStringToFloat(s) else { continue }
                if abs(f - targetFloat) <= tolerance {
                    candidates.append((1, idx, s))
                }
            }
        }
        if candidates.isEmpty { return nil }
        candidates.sort { $0.res != $1.res ? $0.res > $1.res : $0.idx < $1.idx }
        return candidates[0].ratio
    }

    // MARK: - Parsing helpers (port of aspect.py privates)

    private static let otherAspectRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,4})\s*[:x/×]\s*(\d{1,4})\b"#
    )

    private static let supportedRatioRegex = try! NSRegularExpression(
        pattern: #"^(\d+)\s*[:x×]\s*(\d+)$"#
    )

    /// Port of parse_aspect_freeform: "3:4 (960x1280)" -> "3:4"; nil otherwise.
    private static func parseAspectFreeform(_ text: String) -> String? {
        if text.isEmpty { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = otherAspectRegex.firstMatch(in: text, range: full),
              let w = Int(ns.substring(with: m.range(at: 1))),
              let h = Int(ns.substring(with: m.range(at: 2)))
        else { return nil }
        if w <= 0 || h <= 0 { return nil }
        let g = gcd(w, h)
        return "\(w / g):\(h / g)"
    }

    /// Port of _ratio_string_to_dims: "720:960" / "720x960" -> (720, 960).
    private static func ratioStringToDims(_ s: String) -> (Int, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = supportedRatioRegex.firstMatch(in: trimmed, range: full),
              let w = Int(ns.substring(with: m.range(at: 1))),
              let h = Int(ns.substring(with: m.range(at: 2)))
        else { return nil }
        return (w, h)
    }

    /// Port of _ratio_string_to_float: "720:960" -> 0.75; nil if unparseable or 0.
    private static func ratioStringToFloat(_ s: String) -> Double? {
        guard let (w, h) = ratioStringToDims(s) else { return nil }
        if h == 0 { return nil }
        return Double(w) / Double(h)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }
}
