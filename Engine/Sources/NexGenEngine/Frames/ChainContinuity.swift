import Foundation

/// Anchor-and-extend clip-to-clip continuity: when a shot has `chain_with_previous_end`, its start
/// frame is the LAST frame of its predecessor's rendered clip. Port of the rolling `prev_last_frame`
/// bookkeeping in `render/dispatcher.py` (the `needs_last_frame` lookahead + the chain branch of
/// `_resolve_anchor_frames`).
///
/// The Python dispatcher owns a sequential render loop and rolls this state itself. NexGenVideo renders
/// per shot through the agent's record/next tools, so the same decisions are relocated here as pure
/// functions over the shotlist: `record_render` asks `needsLastFrame` (extract this shot's last frame
/// when its successor chains) and `next_render_shot` asks `chainPredecessor` (which earlier shot's last
/// frame conditions this one).
public enum ChainContinuity {
    /// The render order: shots that are actually provider-rendered, by ascending time. Imported shots
    /// are shot-and-cut by the user, never rendered, so they don't participate in the chain — matching
    /// the dispatcher, which pairs only renderable shots.
    static func renderOrder(_ shotlist: Shotlist) -> [Shot] {
        shotlist.shots
            .filter { $0.sourceMode != .imported }
            .sorted { $0.timeStart < $1.timeStart }
    }

    /// True when the shot immediately AFTER `shotId` in render order chains off it — i.e. this shot's
    /// last frame must be extracted after it renders. Port of `needs_last_frame[s.id]`.
    public static func needsLastFrame(_ shotlist: Shotlist, shotId: String) -> Bool {
        let order = renderOrder(shotlist)
        guard let i = order.firstIndex(where: { $0.id == shotId }), i + 1 < order.count else { return false }
        return order[i + 1].chainWithPreviousEnd
    }

    /// The id of the shot whose last frame conditions `shotId`'s start — the immediate predecessor in
    /// render order, but only when `shotId` has `chain_with_previous_end`. nil otherwise. Port of the
    /// `shot.chain_with_previous_end and prev_last_frame` branch.
    public static func chainPredecessor(_ shotlist: Shotlist, shotId: String) -> String? {
        let order = renderOrder(shotlist)
        guard let i = order.firstIndex(where: { $0.id == shotId }),
              order[i].chainWithPreviousEnd, i > 0 else { return nil }
        return order[i - 1].id
    }
}
