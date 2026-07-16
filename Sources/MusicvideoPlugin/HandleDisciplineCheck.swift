import Foundation
import NexGenEngine

/// HANDLE_HOLD_IMPLAUSIBLE (#213) — a shot renders cut-handle material (a held beat of micro-motion at
/// the edge) only if the action can actually hold there. A whip-pan, a hard impact on beat 1, a snap
/// zoom — motion that peaks at the cut — has nothing to hold, so the handle frames won't blend and the
/// rendered overlap is wasted seconds. Warn-level: it's a plausibility hint over the plan, not a block.
extension MusicvideoChecks {
    /// Motion that cannot settle into a held beat — if any appears on a handled shot, the handle is
    /// unlikely to give clean overlap material. Matched as substrings of the shot's motion/visual prompt.
    static let unholdableMotion: [String] = [
        "whip pan", "whip-pan", "whip", "snap zoom", "snap-zoom", "crash zoom",
        "hard impact", "impact", "smash", "slam", "explode", "explosion", "burst",
        "jump cut", "jump-cut", "sudden",
    ]

    public static let handleDisciplineCheck: SanityCheck = { ctx in
        // The global override forces a handle on every shot; otherwise only planned fade/crossfade
        // sides carry one. No brief → treat as no override (planned transitions still apply).
        let forceAll = ctx.brief?.cutHandlesMode == .withOverlap
        var out: [Finding] = []
        for shot in ctx.shotlist.shots {
            let h = CutHandles.handles(for: shot, forceAll: forceAll)
            guard h.pre > 0 || h.post > 0 else { continue }
            let text = (shot.visualPrompt + " " + (shot.motion ?? "")).lowercased()
            guard let hit = unholdableMotion.first(where: { text.contains($0) }) else { continue }
            out.append(Finding(
                level: .warn, code: "HANDLE_HOLD_IMPLAUSIBLE", shotId: shot.id,
                message: "shot \(shot.id) renders cut-handle material for a planned fade/crossfade, but its "
                    + "motion (\"\(hit)\") peaks at the edge and can't hold a still beat there — the handle "
                    + "frames won't blend and you'll pay for unusable overlap. Either drop the transition to a "
                    + "hard cut (no handle) or soften the motion at that edge."))
        }
        return out
    }
}
