import Foundation

/// Per-shot pre-flight estimate. Port of `render/costs.py::ShotEstimate`.
/// `durationS` is the effective render duration (Bug 28: core, WITHOUT overlap).
/// `truncated` is true when clipped to the model limit.
public struct ShotEstimate: Sendable, Equatable {
    public var shotId: String
    public var runwayModel: String
    public var durationS: Double
    public var eur: Double
    public var truncated: Bool
    public var notes: String

    public init(
        shotId: String, runwayModel: String, durationS: Double, eur: Double, truncated: Bool,
        notes: String = ""
    ) {
        self.shotId = shotId
        self.runwayModel = runwayModel
        self.durationS = durationS
        self.eur = eur
        self.truncated = truncated
        self.notes = notes
    }
}

/// Project-wide pre-flight estimate. Port of `render/costs.py::ProjectEstimate`.
public struct ProjectEstimate: Sendable, Equatable {
    public var phase: Phase
    public var mode: Mode
    public var shotEstimates: [ShotEstimate]
    public var totalEur: Double
    public var budgetEur: Double
    public var overBudget: Bool

    public init(
        phase: Phase, mode: Mode, shotEstimates: [ShotEstimate], totalEur: Double, budgetEur: Double,
        overBudget: Bool
    ) {
        self.phase = phase
        self.mode = mode
        self.shotEstimates = shotEstimates
        self.totalEur = totalEur
        self.budgetEur = budgetEur
        self.overBudget = overBudget
    }
}

/// Effective render duration ordered from the model — and billed. #213 reverses the old post-padding
/// model (freeze frames via `ffmpeg tpad`, rejected as slop): cut handles are now CONTENT the model
/// renders, so a handled shot orders its GROSS duration (net + pre/post handle seconds) and pays for it.
/// A shot with no planned transition and no global override is unchanged (gross == net). `costs` stays
/// in the signature to mirror the Python arity.
func seedanceRenderDuration(_ shot: Shot, costs: CostsConfig, mode: Mode, forceHandles: Bool) -> Double {
    let h = CutHandles.handles(for: shot, forceAll: forceHandles)
    guard h.pre > 0 || h.post > 0 else {
        // No handle → the pre-existing behavior exactly: price the shot's own duration. What the agent
        // rounds a fractional net to when ordering is a separate, older question; not this change's.
        return shot.durationS
    }
    // Handled → price EXACTLY what gets ordered. `next_render_shot` hands the agent the ceil'd whole
    // second, so pricing the unrounded gross would under-estimate — and the budget stop (#198) is
    // pre-flight, so an under-estimate lets spend through that the user's limit should have blocked.
    return Double(CutHandles.orderableGrossDuration(for: shot, forceAll: forceHandles))
}

/// Port of `render/costs.py::_stitched_segments` (`max(1, ceil(total/limit))`).
func stitchedSegments(totalS: Double, modelLimitS: Double) -> Int {
    max(1, Int((totalS / modelLimitS).rounded(.up)))
}

/// Resolution choice per model + phase (v0.11.7). Port of
/// `render/costs.py::_resolution_for_phase`.
///
/// Final: use `finalResolution` from the brief; if the model can't do it (Fast
/// has no 1080p) fall back to the model max (720p). Preview: smallest available
/// (720p — 480p isn't priced on fal). Runway models have no semantic resolution
/// concept (ratios carry it) → nil → `eurPerSecond` fallback.
func resolutionForPhase(
    modelId: String, phase: Phase, finalResolution: String = "1080p"
) -> String? {
    guard modelId.hasPrefix("fal:") else { return nil }
    let isFast = modelId.contains("/fast")
    if phase == .final {
        // Brief default 1080p, but Fast has no 1080p.
        if isFast && finalResolution == "1080p" {
            return "720p"  // Fast max
        }
        return finalResolution
    }
    // Preview: smallest available = 720p (480p not offered).
    return "720p"
}

/// Port of `render/costs.py::estimate` — the pre-flight estimate.
///
/// `finalResolution` is threaded from the brief (`brief.final_resolution`); Pro
/// 720p ($0.30/s) vs 1080p ($0.68/s) is a 2.3x factor, so the estimate must
/// reflect it.
public func estimate(
    shotlist: Shotlist, costs: CostsConfig, phase: Phase, finalResolution: String = "1080p",
    forceHandles: Bool = false
) -> ProjectEstimate {
    var estimates: [ShotEstimate] = []
    for shot in shotlist.shots {
        // live_action shots are shot by the user, never provider-rendered → 0 cost. ai_enhanced
        // shots run a provider video-to-video pass, so they're billed like generated (below).
        if shot.sourceMode == .imported {
            estimates.append(
                ShotEstimate(
                    shotId: shot.id, runwayModel: "", durationS: pyRound(shot.durationS, 3), eur: 0.0,
                    truncated: false, notes: "imported"
                )
            )
            continue
        }
        let runwayModel = costs.runwayModel(for: shot, phase: phase)
        // `estimate` calls `costs.price(...)`, which raises for an unknown
        // model. The Python here lets that KeyError propagate; the Swift
        // `runwayModel(for:)` only ever returns models present in a
        // well-formed config, so a force-try mirrors the "must be priced or
        // it's a config bug" contract. `try!` surfaces a misconfig loudly
        // rather than silently mispricing.
        let pricing = try! costs.price(runwayModel)
        let resolution = resolutionForPhase(
            modelId: runwayModel, phase: phase, finalResolution: finalResolution
        )
        let eurPerSecond = pricing.eurPerSecond(for: resolution)

        let rawDuration = seedanceRenderDuration(shot, costs: costs, mode: shotlist.mode, forceHandles: forceHandles)
        var truncated = false
        var padded = false
        let billableS: Double
        let eur: Double
        let note: String

        if shotlist.mode == .beat || shotlist.mode == .phrase {
            if rawDuration > pricing.maxDurationS {
                billableS = pricing.maxDurationS
                truncated = true
            } else if rawDuration < pricing.minDurationS {
                billableS = pricing.minDurationS
                padded = true
            } else {
                billableS = rawDuration
            }
            eur = billableS * eurPerSecond
            var noteParts: [String] = []
            if truncated {
                noteParts.append("truncated to \(pyFloat(pricing.maxDurationS))s")
            }
            if padded {
                noteParts.append(
                    "padded to provider-min \(pyFloat(pricing.minDurationS))s "
                        + "(actual shot \(pyFixed1(rawDuration))s)"
                )
            }
            if let resolution {
                noteParts.append("@\(resolution)")
            }
            note = noteParts.joined(separator: "; ")
        } else {
            let segments = stitchedSegments(totalS: rawDuration, modelLimitS: pricing.maxDurationS)
            billableS = rawDuration
            eur = billableS * eurPerSecond
            var stitchNote = segments > 1 ? "stitch=\(segments)" : ""
            if let resolution {
                stitchNote = stitchNote.isEmpty ? "@\(resolution)" : "\(stitchNote); @\(resolution)"
            }
            note = stitchNote
        }

        estimates.append(
            ShotEstimate(
                shotId: shot.id,
                runwayModel: runwayModel,
                durationS: pyRound(billableS, 3),
                eur: pyRound(eur, 3),
                truncated: truncated,
                notes: note
            )
        )
    }

    let total = pyRound(estimates.reduce(0.0) { $0 + $1.eur }, 2)
    return ProjectEstimate(
        phase: phase,
        mode: shotlist.mode,
        shotEstimates: estimates,
        totalEur: total,
        budgetEur: shotlist.budgetEur,
        overBudget: total > shotlist.budgetEur
    )
}
