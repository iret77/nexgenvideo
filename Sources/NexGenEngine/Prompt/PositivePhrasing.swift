import Foundation

/// Turns "no people" / "avoid X" into fully positive framing. Port of
/// `render/prompt/builder.py::_positive_phrasing`. The table yields phrases with
/// no negation words. Unknown negatives pass through unchanged (the linter's
/// `PROMPT_CONTAINS_NEGATION` catches them).
enum PositivePhrasing {
    /// Verbatim port of the `table` dict. Lookup is by `neg.lower().strip()`.
    static let table: [String: String] = [
        "no people": "empty environment, only architecture and props visible",
        "no figures": "empty environment, only setting visible",
        "no humans": "empty environment, only setting visible",
        "no text": "clean untyped surfaces",
        "no watermarks": "clean unmarked image",
        "no signature": "clean unsigned image",
        "no hands": "framing tight on the object so the holder stays out of frame",
        "no cars": "empty road surface",
        "no logos": "unbranded surfaces",
        "no cgi look": "photorealistic capture quality",
        "no smooth ai skin": "natural skin micro-texture preserved",
        "no artificial facial distortions": "anatomically correct facial features",
        "no jitter": "smooth stable framing with consistent motion",
        "no temporal flicker": "consistent lighting and color across all frames",
        "no identity drift": "the character's design stays identical to the references throughout",
        "no bent limbs": "clean correct anatomy with naturally articulated limbs",
        "avoid jitter": "smooth stable framing with consistent motion",
        "avoid bent limbs":
            "clean correct anatomy, naturally articulated limbs, exactly the right number of limbs",
        "avoid temporal flicker": "consistent lighting and color across all frames",
        "avoid identity drift":
            "the character's design stays identical to the references throughout",
        "no exaggerated cast shadows":
            "each character casts a small short soft shadow pooled at their feet, background shadows stay subtle",
    ]

    static func phrase(_ neg: String) -> String {
        let key = neg.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return table[key] ?? neg
    }
}
