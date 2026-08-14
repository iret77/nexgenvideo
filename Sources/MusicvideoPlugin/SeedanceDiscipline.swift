import Foundation
import NexGenEngine

/// Seedance prompt-quality and duration discipline for video generation.
/// Operates on the frame-zero subject and duration; camera truth is validated
/// separately from the structured production plan.
enum SeedanceTokens {
    /// Vague praise that pulls generators toward generic output (Apiyi / OpenAI cookbook).
    static let slop = [
        "cinematic", "epic", "amazing", "stunning", "masterpiece", "breathtaking",
        "gorgeous", "magnificent", "spectacular", "incredible", "awesome",
        "ultra-detailed", "highly detailed", "award-winning",
    ]
    /// Tokens that reproducibly induce jitter (Apiyi: "fast").
    static let hardBlock = ["fast", "very fast", "super fast", "lightning fast"]
    /// mm / f-stop / ISO / fps / degree specs — generators ignore or corrupt them.
    static let technicalLingo = #"\b(?:\d+\s*mm|f[/.]?\d+(?:\.\d+)?|iso\s*\d+|\d+\s*fps|\d+\s*°)\b"#
}

extension MusicvideoChecks {
    public static let seedanceDisciplineCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let costs = CostsConfig.bundledDefault
        for shot in ctx.shotlist.shots {
            let p = shot.visualPrompt
            let pLow = p.lowercased()

            // 1. Hard-block jitter tokens (one finding per matching token — matches the reference loop).
            for tok in SeedanceTokens.hardBlock where matchesWord(tok, in: pLow) {
                out.append(Finding(level: .error, code: "PROMPT_HARD_BLOCK_TOKEN", shotId: shot.id,
                    message: "token \"\(tok)\" in visual_prompt — Apiyi guide: reproducibly induces jitter. "
                        + "Replace with a concrete speed phrase ('slow', 'measured', 'languid' for slow; "
                        + "'brisk', 'urgent' for fast). Sanity blocks the render until the word is gone."))
            }

            // 2. Slop adjectives do not belong in the frame-zero subject.
            let hasSlop = SeedanceTokens.slop.contains { matchesWord($0, in: pLow) }
            if hasSlop {
                out.append(Finding(level: .error, code: "PROMPT_QUALITY_KILLER", shotId: shot.id,
                    message: "generic praise ('cinematic'/'epic'/'stunning'/'gorgeous') in visual_prompt. "
                        + "Replace it with a concrete frame-zero subject detail."))
            }

            // 3. Technical lingo (mm / f-stop / ISO / fps / degrees).
            let tech = matches(SeedanceTokens.technicalLingo, in: p)
            if !tech.isEmpty {
                let samples = tech.prefix(3).joined(separator: ", ")
                out.append(Finding(level: .error, code: "PROMPT_TECHNICAL_LINGO", shotId: shot.id,
                    message: "technical specs in the prompt (\"\(samples)\"). Generators don't parse "
                        + "mm/f-stop/ISO/fps reliably. Use composition language instead: 'shallow depth of "
                        + "field', 'normal lens feel', 'wide-angle distortion'. Sanity blocks the render."))
            }

            // 4/5. Duration claims come from the versioned pack capability catalog.
            let model = costs.runwayModel(for: shot, phase: .final)
            if let maximum = ModelCapabilities.capability(model)?.maxDurationS,
               shot.durationS > maximum {
                out.append(Finding(level: .warn, code: "SHOT_OVER_SEEDANCE_CAP", shotId: shot.id,
                    message: String(
                        format: "duration_s=%.1fs > %@ max=%.1fs. Split the shot or select a model that supports it.",
                        shot.durationS, model, maximum
                    )))
            }
            if let minimum = ModelCapabilities.minimumDuration(model), shot.durationS < minimum {
                let extra = minimum - shot.durationS
                out.append(Finding(level: .info, code: "SHOT_UNDER_SEEDANCE_MIN", shotId: shot.id,
                    message: String(format: "duration_s=%.1fs < %@ min=%.1fs. The render rounds up "
                        + "(+%.1fs output and render cost); crop to the planned %.1fs.",
                        shot.durationS, model, minimum, extra, shot.durationS)))
            }
        }
        return out
    }

    /// Whole-word (regex `\b…\b`) match of a literal token in already-lowercased text.
    private static func matchesWord(_ token: String, in lower: String) -> Bool {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: token))\\b"
        return lower.range(of: pattern, options: .regularExpression) != nil
    }

    /// All substrings of `text` matching `pattern` (case-insensitive), in order.
    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}
