import Foundation

/// Structural subject-blocking validation for a shot's frame-zero prompt. A shot with
/// `keyframe_strategy ∈ {start, start_end}` must cover two axes in `visual_prompt`:
///   POSE   — a present-tense pose verb AND a body-part detail,
///   VECTOR — the next-movement intent,
/// A figure-less cutaway skips both; camera truth remains in the structured shot fields.
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

    /// Validate the subject axes. Only meaningful for `keyframe_strategy ∈ {start, start_end}`.
    public static func validate(visualPrompt: String, hasCharacters: Bool) -> Result {
        let text = visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let figureless = !(hasCharacters || hasPersonHint(visualPrompt))

        let poseVerbOK = figureless || hasAny(text, poseVerbs)
        let poseBodyOK = figureless || hasAny(text, poseBodyParts)
        let poseOK = figureless || (poseVerbOK && poseBodyOK)
        let vectorOK = figureless || hasAny(text, vectorMarkers)

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
        return Result(ok: poseOK && vectorOK, reasons: reasons)
    }
}
