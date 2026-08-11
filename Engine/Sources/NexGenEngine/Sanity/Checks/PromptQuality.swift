import Foundation

/// Per-shot frame-zero subject quality.
///
/// - `PROMPT_TOO_SHORT` (error): a prompt this short cannot identify a concrete subject.
/// - `PROMPT_GENERIC` (warn): generic adjectives ("epic", "cinematic
///   masterpiece") without concrete image description — slop risk.
///
/// This is the format-neutral core of a pack's richer prompt checks; the
/// metaphor / undefined-group / title-card / blocking heuristics stay out of
/// the engine because they depend on pack-specific validators. Port of
/// `sanity/checks/prompt_quality.py::check`.
public let promptQualityCheck: SanityCheck = { ctx in
    let shortLen = 12
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
                    message: "visual_prompt only \(p.count) chars — no concrete frame-zero subject"
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
