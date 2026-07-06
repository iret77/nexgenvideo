import Foundation

/// Hybrid-production source-mode reporting (issue #129).
///
/// - `SOURCE_MODE_COVERAGE` (info): a per-mode count of shots (generated /
///   live_action / ai_enhanced). Always emitted so the report states the mix.
/// - `SOURCE_MODE_NEEDS_FOOTAGE` (info): flags each `live_action` /
///   `ai_enhanced` shot, which needs footage the user shoots or imports. The
///   shot↔clip provenance that would prove footage is *assigned* lives app-side
///   (the timeline / render-path ObjectGraph), not in the engine's
///   `AuditContext` (shotlist + brief + bible only) — so this check reports mode
///   membership, not resolved linkage.
public let sourceModeCoverageCheck: SanityCheck = { ctx in
    var out: [Finding] = []
    let shots = ctx.shotlist.shots

    var counts: [SourceMode: Int] = [:]
    for shot in shots { counts[shot.sourceMode, default: 0] += 1 }

    // Only report the mix when it's actually hybrid — a wholly generated project
    // (the default) needs no source-mode note.
    let generated = counts[.generated, default: 0]
    let live = counts[.liveAction, default: 0]
    let enhanced = counts[.aiEnhanced, default: 0]
    if live > 0 || enhanced > 0 {
        out.append(
            Finding(
                level: .info,
                code: "SOURCE_MODE_COVERAGE",
                message: "source modes — generated: \(generated), live_action: \(live), ai_enhanced: \(enhanced)"
            )
        )
    }

    for shot in shots {
        switch shot.sourceMode {
        case .generated:
            continue
        case .liveAction:
            out.append(
                Finding(
                    level: .info, code: "SOURCE_MODE_NEEDS_FOOTAGE", shotId: shot.id,
                    message: "live action — shoot to the directorial spec, then cut in on the timeline"
                )
            )
        case .aiEnhanced:
            out.append(
                Finding(
                    level: .info, code: "SOURCE_MODE_NEEDS_FOOTAGE", shotId: shot.id,
                    message: "ai_enhanced — import the source footage, then run the video-to-video edit pass"
                )
            )
        }
    }

    return out
}
