import Foundation

/// Per-shot visual-prompt quality (length + generic-slop heuristics).
///
/// - `PROMPT_TOO_SHORT` (error): a prompt this short cannot carry the required
///   components (subject+action / position / setting / camera / light+mood).
/// - `PROMPT_THIN` (warn): borderline — one of those components is probably
///   too terse.
/// - `PROMPT_GENERIC` (warn): generic adjectives ("epic", "cinematic
///   masterpiece") without concrete image description — slop risk.
///
/// This is the format-neutral core of a pack's richer prompt checks; the
/// metaphor / undefined-group / title-card / blocking heuristics stay out of
/// the engine because they depend on pack-specific validators. Port of
/// `sanity/checks/prompt_quality.py::check`.
public let promptQualityCheck: SanityCheck = { ctx in
    let shortLen = 60
    let thinLen = 120
    let genericTokens = ["epic", "cinematic masterpiece"]
    let genericMaxLen = 200

    var out: [Finding] = []
    for shot in ctx.shotlist.shots {
        let p = shot.visualPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count < shortLen {
            out.append(
                Finding(
                    level: .error,
                    code: "PROMPT_TOO_SHORT",
                    shotId: shot.id,
                    message:
                        "visual_prompt only \(p.count) chars — missing required components "
                        + "(subject+action / position / setting / camera / light+mood)"
                )
            )
        } else if p.count < thinLen {
            out.append(
                Finding(
                    level: .warn,
                    code: "PROMPT_THIN",
                    shotId: shot.id,
                    message:
                        "visual_prompt only \(p.count) chars — one of the required components "
                        + "is probably too terse"
                )
            )
        }

        let lower = p.lowercased()
        if genericTokens.contains(where: { lower.contains($0) }) && p.count < genericMaxLen {
            out.append(
                Finding(
                    level: .warn,
                    code: "PROMPT_GENERIC",
                    shotId: shot.id,
                    message: "generic adjectives without concrete image description — slop risk"
                )
            )
        }
    }
    return out
}
