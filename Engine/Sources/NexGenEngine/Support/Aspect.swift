import Foundation

/// Aspect-ratio mapping: a Brief's semantic aspect ("16:9", "9:16", …) to
/// per-provider formats (Runway pixel strings, OpenAI pixel strings, floats),
/// plus freeform parsing and tolerance matching against a model's supported
/// ratios. Port of `core/aspect.py` — the single source of truth for all
/// render/sheet aspect resolution. Kept as pure value functions.
public enum Aspect {
    /// Semantic aspect → float ratio (W/H). Port of `ASPECT_TO_FLOAT`.
    public static let toFloat: [String: Double] = [
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

    /// Semantic aspect → Runway pixel string. Port of `ASPECT_TO_RUNWAY_PIXEL`.
    public static let toRunwayPixel: [String: String] = [
        "16:9": "1280:720",
        "9:16": "720:1280",
        "1:1": "960:960",
        "4:5": "832:1104",
        "5:4": "1104:832",
        "4:3": "960:720",
        "3:4": "720:960",
        "21:9": "2560:1080",
        "9:21": "1080:2560",
    ]

    /// Semantic aspect → OpenAI (GPT-Image) pixel string. Port of `ASPECT_TO_OPENAI_PIXEL`.
    public static let toOpenAIPixel: [String: String] = [
        "16:9": "1536x1024",
        "9:16": "1024x1536",
        "1:1": "1024x1024",
        "4:3": "1536x1024",
        "3:4": "1024x1536",
    ]

    /// Aspect string → Runway pixel string. Falls back to `1280:720` (never an
    /// empty string — the Runway SDK would fail). Port of `to_runway_ratio`.
    public static func toRunwayRatio(_ aspect: String) -> String {
        toRunwayPixel[aspect] ?? "1280:720"
    }

    /// Aspect string → OpenAI pixel string. Fallback `1024x1024`. Port of `to_openai_ratio`.
    public static func toOpenAIRatio(_ aspect: String) -> String {
        toOpenAIPixel[aspect] ?? "1024x1024"
    }

    /// Aspect string → float (W/H), or nil if unknown. Port of `aspect_float`.
    public static func aspectFloat(_ aspect: String) -> Double? {
        toFloat[aspect]
    }

    /// Matches the leading `W:H` (or `WxH` / `W/W` / `W×H`) token in freeform
    /// text. Port of `_OTHER_ASPECT_RE`. `nonisolated(unsafe)`: NSRegularExpression
    /// matching is thread-safe (matches the codebase's shared-static idiom).
    nonisolated(unsafe) private static let otherAspectRegex = try! NSRegularExpression(
        pattern: #"\b(\d{1,4})\s*[:x/×]\s*(\d{1,4})\b"#
    )

    /// "3:4 (960x1280)" → "3:4". Pixel pairs (960x1280) are reduced to their
    /// semantic ratio via GCD. Nil when nothing usable. Port of `parse_aspect_freeform`.
    public static func parseFreeform(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = otherAspectRegex.firstMatch(in: text, range: range),
              let wRange = Range(match.range(at: 1), in: text),
              let hRange = Range(match.range(at: 2), in: text),
              let w = Int(text[wRange]), let h = Int(text[hRange]),
              w > 0, h > 0
        else { return nil }
        let g = gcd(w, h)
        return "\(w / g):\(h / g)"
    }

    /// Raised when a brief's aspect can't be resolved to a concrete W:H. Port of
    /// `AspectUnresolvable`.
    public struct Unresolvable: Swift.Error, Sendable, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// A brief's semantic aspect ("3:4" etc.). When `aspectRatio` is "other",
    /// `aspectRatioOther` is parsed. Throws `Unresolvable` when neither yields a
    /// concrete aspect — so the silent-16:9 fallback can never run again. Port of
    /// `resolve_brief_aspect`, taking the two fields directly (the pure engine
    /// has no live Brief object dependency here).
    public static func resolveBriefAspect(aspectRatio: String?, aspectRatioOther: String?) throws -> String {
        guard let aspectRatio else {
            throw Unresolvable("brief has no aspect_ratio field")
        }
        if !aspectRatio.isEmpty, aspectRatio != "other" {
            return aspectRatio
        }
        let freeform = aspectRatioOther ?? ""
        guard let parsed = parseFreeform(freeform) else {
            throw Unresolvable(
                "brief.aspect_ratio=other and aspect_ratio_other=\(freeform.debugDescription) "
                    + "yields no W:H. Re-set the brief with a concrete aspect (e.g. '3:4')."
            )
        }
        return parsed
    }

    /// "720:960" / "720x960" → (720, 960). Nil if unparseable. Port of
    /// `_SUPPORTED_RATIO_RE` + `_ratio_string_to_dims`.
    nonisolated(unsafe) private static let supportedRatioRegex = try! NSRegularExpression(
        pattern: #"^(\d+)\s*[:x×]\s*(\d+)$"#
    )

    static func ratioStringToDims(_ s: String) -> (Int, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = supportedRatioRegex.firstMatch(in: trimmed, range: range),
              let wRange = Range(match.range(at: 1), in: trimmed),
              let hRange = Range(match.range(at: 2), in: trimmed),
              let w = Int(trimmed[wRange]), let h = Int(trimmed[hRange])
        else { return nil }
        return (w, h)
    }

    static func ratioStringToFloat(_ s: String) -> Double? {
        guard let (w, h) = ratioStringToDims(s), h != 0 else { return nil }
        return Double(w) / Double(h)
    }

    /// Resolve an aspect string semantically against a model's supported ratios,
    /// within `tolerance` on the float ratio, preferring the highest-resolution
    /// match. Nil when nothing matches (a real cap mismatch). Port of
    /// `resolve_for_model`.
    public static func resolveForModel(
        _ aspect: String, supportedRatios: [String], tolerance: Double = 0.05
    ) -> String? {
        guard !supportedRatios.isEmpty else { return nil }
        guard let targetFloat = aspectFloat(aspect) ?? ratioStringToFloat(aspect) else { return nil }
        var candidates: [(score: Int, value: String)] = []
        for s in supportedRatios {
            if let (w, h) = ratioStringToDims(s) {
                guard h != 0 else { continue }
                let f = Double(w) / Double(h)
                if abs(f - targetFloat) <= tolerance { candidates.append((w * h, s)) }
            } else {
                // e.g. a Google-style aspect string "16:9" — compare by float.
                guard let f = toFloat[s] ?? ratioStringToFloat(s) else { continue }
                if abs(f - targetFloat) <= tolerance { candidates.append((1, s)) }
            }
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.score > $1.score }
        return candidates[0].value
    }

    /// Resolve to a provider-compatible ratio; on no match, fall back to
    /// `supportedRatios[0]` (aspect distortion — the caller should check).
    /// Port of `resolve_for_provider`.
    public static func resolveForProvider(_ aspect: String, supportedRatios: [String]) -> String {
        guard !supportedRatios.isEmpty else { return aspect }
        return resolveForModel(aspect, supportedRatios: supportedRatios) ?? supportedRatios[0]
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}
