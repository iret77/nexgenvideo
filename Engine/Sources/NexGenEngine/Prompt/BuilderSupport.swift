import Foundation

/// Shared builder helpers and constants. Port of the module-level helpers in
/// `builder.py`: `_join_clean`, the SEEDANCE_* positive constants, the cartoon
/// shadow constraint, and the pacing block.
enum BuilderSupport {
    /// Port of `_join_clean`. Trims each part, drops empties, ensures each ends
    /// with terminal punctuation, joins with a single space.
    static func joinClean(_ parts: [String]) -> String {
        var out: [String] = []
        for raw in parts {
            var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            if let last = p.last, !".!?".contains(last) {
                p += "."
            }
            out.append(p)
        }
        return out.joined(separator: " ")
    }

    /// Port of `SEEDANCE_STANDARD_VIDEO_POSITIVES`.
    static let seedanceStandardVideoPositives: [String] = [
        "smooth stable framing with consistent motion",
        "clean correct anatomy, naturally articulated limbs, exactly the right number of limbs",
        "consistent lighting and color across all frames",
        "the character's design stays identical to the references throughout",
    ]

    /// Port of `SEEDANCE_CHARACTER_POSITIVES`.
    static let seedanceCharacterPositives: [String] = [
        "the character's facial features remain identical to the references",
        "body proportions stay identical to the references",
    ]

    /// Port of `_CARTOON_STYLE_PATTERN`. Case-insensitive, word-boundaried.
    static let cartoonStylePattern = Rx.compile(
        #"\b(cartoon|cel[\s-](?:animation|shaded|shading|style)|flat[\s-]2d|2d[\s-]animation|anime|hanna[\s-]barbera|ghibli|looney[\s-]tunes|comic[\s-]book|vector[\s-]style)\b"#,
        caseInsensitive: true
    )

    /// Port of `_cartoon_shadow_constraint`.
    static func cartoonShadowConstraint(_ payload: PromptPayload) -> String? {
        let text = "\(payload.style) \(payload.subject)"
        guard Rx.search(text, cartoonStylePattern) else { return nil }
        return "flat even cartoon lighting; each character casts only a small "
            + "short soft shadow pooled at their feet; background shadows "
            + "stay subtle and consistent with the flat cel style"
    }

    /// Port of `_seedance_pacing_block`.
    static func seedancePacingBlock(_ durationS: Double?, isPacingArm: Bool) -> String? {
        guard let durationS, durationS > 0 else { return nil }
        if durationS < 5.0 && !isPacingArm { return nil }
        if isPacingArm {
            let d = String(format: "%.0f", durationS)
            return "Pace this ~\(d)s shot naturally. "
                + "Open with ~1s of settled idle (subtle breathing, small "
                + "weight shift), perform the described action at a natural "
                + "lifelike tempo, then hold a relaxed idle pose until the end. "
                + "Use the idle holds before and after as the time-fill so the "
                + "action itself stays at natural lifelike speed throughout. "
                + "Keep subtle living motion across the whole clip."
        }
        return "Natural lifelike tempo throughout, with subtle living motion across the whole clip."
    }
}
