import Foundation

/// Shotlist vs brief consistency: `MODE_MISMATCH`.
///
/// The brief declares the project mode up front; the shotlist carries a
/// concrete `Mode`. If they disagree the shotlist was generated against a
/// different layout than the brief asked for. Returns nothing when there is
/// no brief. Port of `sanity/checks/mode_match.py::check`.
public let modeMatchCheck: SanityCheck = { ctx in
    guard let brief = ctx.brief else { return [] }
    guard brief.projectMode != ctx.shotlist.mode.rawValue else { return [] }
    return [
        Finding(
            level: .error,
            code: "MODE_MISMATCH",
            message:
                "shotlist mode=\(ctx.shotlist.mode.rawValue), brief project_mode=\(brief.projectMode)"
        )
    ]
}
