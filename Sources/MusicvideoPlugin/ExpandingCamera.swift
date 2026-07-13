import Foundation
import NexGenEngine

/// Camera-move classification — port of `storyboard/camera_validator.py::is_expanding_move`. An
/// "expanding" move brings NEW world area into frame (pan/pull/tilt/track/orbit/crane, zoom-out), so a
/// still-image start frame can't anchor it — the video model must invent the newly-visible area
/// (usually slop). Such shots want a start_end pair so the model interpolates between two known frames.
enum CameraMoves {
    private static let movePatterns: [(category: String, patterns: [String])] = [
        ("push", ["push-in", "push in", "dolly-in", "dolly in"]),
        ("pull", ["pull-out", "pull out", "pull-back", "pullback", "pull back", "dolly-out", "dolly out"]),
        ("pan", ["pan ", "panning", " pan", "whip pan", "whip-pan"]),
        ("tilt", ["tilt up", "tilt down", "tilts up", "tilts down", "tilting"]),
        ("track", ["tracking shot", "tracking ", "track ", "dolly shot", "dolly along", "trucking"]),
        ("orbit", ["orbit", "circle around", "rotate around"]),
        ("crane", ["crane up", "crane down", "boom up", "boom down", "jib"]),
        ("zoom", ["zoom-in", "zoom in", "zoom-out", "zoom out"]),
        ("aerial", ["aerial", "drone shot", "overhead drone"]),
        ("handheld", ["handheld", "shaky cam", "shaky-cam"]),
    ]
    private static let expandingMoves: Set<String> = ["pull", "pan", "tilt", "track", "orbit", "crane", "zoom", "aerial"]
    private static let zoomExpandingPatterns = ["zoom-out", "zoom out", "zoom back"]
    private static let noMoveTokens = [
        "static", "locked-off", "locked off", "stationary", "fixed camera",
        "no camera movement", "no movement", "still camera",
    ]

    static func isExpandingMove(_ cameraText: String) -> Bool {
        guard !cameraText.isEmpty else { return false }
        let lower = cameraText.lowercased()
        let categories = movePatterns.compactMap { entry in
            entry.patterns.contains(where: { lower.contains($0) }) ? entry.category : nil
        }
        let hasNoMoveSignal = noMoveTokens.contains(where: { lower.contains($0) })
        if hasNoMoveSignal && categories.isEmpty { return false }
        for category in categories {
            switch category {
            case "zoom": if zoomExpandingPatterns.contains(where: { lower.contains($0) }) { return true }
            case "aerial": continue  // aerial alone is a still overhead; 'aerial pan/track' matches via those cats
            default: if expandingMoves.contains(category) { return true }
            }
        }
        return false
    }
}

extension MusicvideoChecks {
    /// EXPANDING_CAMERA — port of `sanity/checks/expanding_camera.py`. An expanding camera move without an
    /// end frame makes the video model extrapolate the newly-visible world (hallucinated architecture,
    /// gibberish text, wasted credits). Escapes: `keyframe_end_skip_ok: <reason>` in Shot.notes.
    public static let expandingCameraCheck: SanityCheck = { ctx in
        var out: [Finding] = []
        let costs = CostsConfig.bundledDefault
        for shot in ctx.shotlist.shots {
            let notes = (shot.notes ?? "").lowercased()
            switch shot.keyframeStrategy {
            case .startEnd:
                // Already has an end frame — but a two-image pair drifts unless a strategy is documented.
                if !notes.contains("frame_pair_strategy:") {
                    out.append(Finding(level: .info, code: "FRAME_PAIR_NO_STRATEGY_DOCUMENTED", shotId: shot.id,
                        message: "keyframe_strategy=start_end set, but no frame_pair_strategy: marker in Shot.notes. "
                            + "World drift between start and end is common (two separate generations render world "
                            + "content slightly differently). Document the strategy: 'frame_pair_strategy: "
                            + "crop_from_master' | 'image_to_image_edit' | 'anchor_and_extend' | 'marble_safe_region' "
                            + "| 'two_separate_generations (reason)'."))
                }
                continue
            case .none:
                continue  // MISSING_BIBLE_ANCHOR_FOR_T2V handles the no-keyframe case
            case .start:
                break
            }
            if notes.contains("keyframe_end_skip_ok:") { continue }
            let cameraText = shot.visualPrompt + " " + (shot.motion ?? "")
            guard CameraMoves.isExpandingMove(cameraText) else { continue }
            let supportsEnd = ModelCapabilities.capability(costs.runwayModel(for: shot, phase: .final))?.supportsKeyframeEnd ?? false
            if supportsEnd {
                out.append(Finding(level: .warn, code: "EXPANDING_CAMERA_NEEDS_END_FRAME", shotId: shot.id,
                    message: "Camera move brings new world area into frame (pan/pull/tilt/track/orbit/crane/zoom-out) "
                        + "but keyframe_strategy=\(shot.keyframeStrategy.rawValue) (no end frame). The video model must "
                        + "invent the newly-visible area — almost always slop (hallucinated architecture, gibberish "
                        + "text). Fix: set keyframe_strategy=start_end AND generate an end frame. Intentional? "
                        + "`keyframe_end_skip_ok: <reason>` in Shot.notes."))
            } else {
                out.append(Finding(level: .info, code: "EXPANDING_CAMERA_NO_END_KEYFRAME_SUPPORT", shotId: shot.id,
                    message: "Camera move brings new world area into frame, but the chosen model supports no end "
                        + "keyframe. Pick another model (e.g. seedance2) or reduce the camera move (static / push "
                        + "instead of pull)."))
            }
        }
        return out
    }
}
