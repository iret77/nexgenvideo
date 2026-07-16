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
            // Name the remedy that actually applies. The two sources are independent and can BOTH be in
            // play on one shot (e.g. a planned fade out while the override forces the pre-handle), so a
            // single either/or would send the user to a no-op for whichever side it missed.
            let anyForced = forceAll
                && (!shot.transitionIn.needsHandle || !shot.transitionOut.needsHandle)
            let anyPlanned = shot.transitionIn.needsHandle || shot.transitionOut.needsHandle
            var remedies: [String] = []
            if anyPlanned { remedies.append("drop the planned transition to a hard cut") }
            if anyForced { remedies.append("turn off the cut_handles_mode=with_overlap override") }
            remedies.append("soften the motion at that edge")
            let remedy = "To fix: " + remedies.joined(separator: ", or ") + "."
            out.append(Finding(
                level: .warn, code: "HANDLE_HOLD_IMPLAUSIBLE", shotId: shot.id,
                message: "shot \(shot.id) renders cut-handle material, but its motion (\"\(hit)\") peaks at "
                    + "the edge and can't hold a still beat there — the handle frames won't blend and you'll "
                    + "pay for unusable overlap. " + remedy))
        }
        out.append(contentsOf: boundaryConsistency(ctx.shotlist))
        return out
    }

    /// HANDLE_BOUNDARY_MISMATCH — a fade/crossfade needs overlap material on BOTH sides of the cut. When
    /// one shot declares a transition out that its successor doesn't declare in (or vice versa), only one
    /// side renders a handle and the blend is starved.
    ///
    /// Adjacency is by TIMELINE order (`time_start`), not array order — "the cut between two shots" is a
    /// timeline fact, and the rest of the engine orders shots the same way (`ChainContinuity.renderOrder`).
    /// A shotlist stored out of order would otherwise be checked across boundaries that don't exist.
    private static func boundaryConsistency(_ shotlist: Shotlist) -> [Finding] {
        let shots = shotlist.shots.sorted { $0.timeStart < $1.timeStart }
        guard shots.count > 1 else { return [] }
        var out: [Finding] = []
        for i in 0..<(shots.count - 1) {
            let a = shots[i], b = shots[i + 1]
            if a.transitionOut.needsHandle != b.transitionIn.needsHandle {
                out.append(Finding(
                    level: .warn, code: "HANDLE_BOUNDARY_MISMATCH", shotId: a.id,
                    message: "the cut between \(a.id) (transition_out: \(a.transitionOut.rawValue)) and "
                        + "\(b.id) (transition_in: \(b.transitionIn.rawValue)) is a "
                        + "fade/crossfade on one side only — the blend needs overlap material on BOTH shots. "
                        + "Set the matching transition on the other side, or make it a hard cut on both."))
            }
        }
        return out
    }
}
