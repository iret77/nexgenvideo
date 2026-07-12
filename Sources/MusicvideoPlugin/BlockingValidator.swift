import Foundation

/// Structural blocking validation for a shot's visual prompt — a faithful port of the original
/// `sanity/blocking_validator.py`. A shot with `keyframe_strategy ∈ {start, start_end}` must cover
/// THREE axes in its `visual_prompt`, not magic strings:
///   POSE   — a present-tense pose verb AND a body-part detail,
///   VECTOR — the next-movement intent,
///   CAMERA — a framing anchor AND a camera-move marker.
/// A figure-less cutaway (no character refs and no person hint) skips POSE/VECTOR; CAMERA stays
/// mandatory (even an empty room needs a framing). This blocks both the old "START FRAME:" magic
/// preamble and empty stub prompts.
public enum BlockingValidator {
    public struct Result: Sendable, Equatable {
        public let ok: Bool
        public let reasons: [String]
    }

    private static let poseVerbs = ["steht", "sitzt", "kniet", "kauert", "lehnt", "hält", "blickt",
        "schaut", "streckt", "legt", "wirft", "zeigt", "greift", "hebt", "senkt", "neigt", "stützt",
        "umarmt", "öffnet", "schließt", "stands", "sits", "kneels", "leans", "holds", "looks", "gazes",
        "reaches", "lifts", "lowers", "tilts", "rests", "opens", "closes"]
    private static let poseBodyParts = ["bein", "fuß", "fuss", "hand", "arm", "schulter", "kopf", "blick",
        "gesicht", "hüfte", "knie", "rücken", "brust", "finger", "ellbogen", "haar", "haare", "leg",
        "foot", "feet", "shoulder", "head", "gaze", "face", "hip", "knee", "back", "chest", "elbow", "hair"]
    private static let vectorMarkers = ["about to", "im begriff", "im moment vor", "kurz bevor",
        "kurz davor", "gleich wird", "gleich setzt", "wird gleich", "wird sich gleich", "bevor er",
        "bevor sie", "bevor das", "dabei zu", "im ansatz"]
    private static let cameraFramingMarkers = ["wide shot", "wide-shot", "medium shot", "medium-shot",
        "wide-angle", "close-up", "close up", "extreme close", "totale", "halbtotale", "halbnah",
        "amerikanisch", "establishing shot", "großaufnahme", "nahaufnahme", "mm-look", "kamera bei",
        "camera at", "framing bei"]
    private static let cameraFramingPatterns = [#"\b(\d+)\s*mm\b"#, #"\b(\d+(?:\.\d+)?)\s*m\b"#,
        #"\bgroß(?:aufnahme)?\b"#, #"\bwide\b(?=[\s,;:.\-])"#, #"\bclose\b(?=[\s,;:.\-])"#,
        #"\bmedium\b(?=[\s,;:.\-])"#]
    private static let cameraMoveMarkers = ["statisch", "static", "still", "dolly", "kran", "crane",
        "schwenk", "rückfahrt", "vorfahrt", "tracking", "fahrt", "rückwärts", "vorwärts", "neigung",
        "push-in", "pull-out"]
    private static let cameraMovePatterns = [#"\bpan\b"#, #"\btilt\b"#, #"\bzoom\b"#]
    private static let personTokens = ["person", "mensch", "menschen", "figur", "figuren", "mann",
        "männer", "frau", "frauen", "junge", "jungen", "mädchen", "kind", "kinder", "leute", "darsteller",
        "schüler", "lehrer", "passant", "people", "character", "man", "woman", "boy", "girl", "child",
        "children", "performer", "dancer", "singer", "musician", "pedestrian", "crowd", "figure", "subject"]
    private static let negationBeforePerson = #"\b(?:no|none|without|empty|keine?[rsm]?|ohne|leer(?:e[rs]?)?)(?:\W+\w+){0,3}\W+(?:person|persons|people|mensch|menschen|figur|figuren|leute|character|characters|subject|subjects|man|men|woman|women|kind|kinder|crowd|darsteller|figure|figures)\b"#
    private static let subjectStructural = #"(^|\n)\s*(?:subject|szene|scene|setting|environment)\s*:"#

    private static func regexMatches(_ text: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Word-boundary match for single words, substring for phrases (matches the Python `_has_any`).
    private static func hasAny(_ text: String, _ markers: [String]) -> Bool {
        for m in markers {
            if m.contains(" ") || m.contains("-") {
                if text.contains(m) { return true }
            } else if regexMatches(text, #"\b\#(NSRegularExpression.escapedPattern(for: m))\b"#) {
                return true
            }
        }
        return false
    }

    private static func hasAnyPattern(_ text: String, _ patterns: [String]) -> Bool {
        patterns.contains { regexMatches(text, $0) }
    }

    public static func hasPersonHint(_ visualPrompt: String) -> Bool {
        guard !visualPrompt.isEmpty else { return false }
        var textLower = visualPrompt.lowercased()
        // Mask structural "subject:"/"scene:" line prefixes so they don't count as a person hint.
        if let re = try? NSRegularExpression(pattern: subjectStructural, options: [.caseInsensitive]) {
            textLower = re.stringByReplacingMatches(
                in: textLower, range: NSRange(textLower.startIndex..., in: textLower), withTemplate: "$1")
        }
        guard hasAny(textLower, personTokens) else { return false }
        return !regexMatches(textLower, negationBeforePerson)
    }

    /// Validate the three axes. Only meaningful for `keyframe_strategy ∈ {start, start_end}`.
    public static func validate(visualPrompt: String, hasCharacters: Bool) -> Result {
        let text = visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let figureless = !(hasCharacters || hasPersonHint(visualPrompt))

        let poseVerbOK = figureless || hasAny(text, poseVerbs)
        let poseBodyOK = figureless || hasAny(text, poseBodyParts)
        let poseOK = figureless || (poseVerbOK && poseBodyOK)
        let vectorOK = figureless || hasAny(text, vectorMarkers)

        let camFrame = hasAny(text, cameraFramingMarkers) || hasAnyPattern(text, cameraFramingPatterns)
        let camMove = hasAny(text, cameraMoveMarkers) || hasAnyPattern(text, cameraMovePatterns)
        let cameraOK = camFrame && camMove

        var reasons: [String] = []
        if !poseOK {
            var missing: [String] = []
            if !poseVerbOK { missing.append("a pose verb (stands/sits/kneels/leans/holds/looks/…)") }
            if !poseBodyOK { missing.append("a body-part detail (leg/hand/shoulder/gaze/…)") }
            reasons.append("POSE missing: needs " + missing.joined(separator: " AND ")
                + " — a magic preamble like 'START FRAME:' isn't enough.")
        }
        if !vectorOK {
            reasons.append("VECTOR missing: needs the next-movement intent (e.g. 'about to …', 'kurz bevor …').")
        }
        if !cameraOK {
            var missing: [String] = []
            if !camFrame { missing.append("a framing anchor (medium/wide/close or ~Xm/Xmm)") }
            if !camMove { missing.append("a camera-move marker (static/dolly/pan/…)") }
            reasons.append("CAMERA missing: " + missing.joined(separator: " AND ") + ".")
        }
        return Result(ok: poseOK && vectorOK && cameraOK, reasons: reasons)
    }
}
