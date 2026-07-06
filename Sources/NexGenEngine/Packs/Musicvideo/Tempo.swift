import Foundation

/// Tempo-dependent shot-pacing guidance. Port of `nexgen_pack_musicvideo/tempo.py`.
///
/// Music videos have decades-grown ASL conventions (Average Shot Length) per
/// tempo class. The `hardCap` is the threshold above which a shot is
/// structurally suspect — either a deliberate breaker (outro hold, bridge
/// negative space) or the pacing is drifting off.
public struct TempoBand: Sendable, Equatable {
    public let label: String
    /// Inclusive.
    public let bpmMin: Double
    /// Exclusive — last band's max is a sentinel.
    public let bpmMax: Double
    public let aslMin: Double
    public let aslTarget: Double
    public let aslMax: Double
    public let hardCap: Double

    public init(
        label: String, bpmMin: Double, bpmMax: Double, aslMin: Double, aslTarget: Double, aslMax: Double,
        hardCap: Double
    ) {
        self.label = label
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.aslMin = aslMin
        self.aslTarget = aslTarget
        self.aslMax = aslMax
        self.hardCap = hardCap
    }

    /// Short, direction-ready description for prompt injection. Port of
    /// `TempoBand.describe`.
    public func describe() -> String {
        String(
            format: "%@ (%.0f-%.0f BPM): ASL %.0f-%.0f s (target ~%.0f s), single shots at most ~%.0f s",
            label, bpmMin, bpmMax, aslMin, aslMax, aslTarget, hardCap
        )
    }
}

/// Port of `tempo.py::TEMPO_BANDS`.
public let tempoBands: [TempoBand] = [
    TempoBand(label: "uptempo_dance", bpmMin: 120.0, bpmMax: 999.0, aslMin: 1.0, aslTarget: 1.5, aslMax: 2.0, hardCap: 4.0),
    TempoBand(label: "midtempo_pop", bpmMin: 90.0, bpmMax: 120.0, aslMin: 2.0, aslTarget: 3.0, aslMax: 4.0, hardCap: 6.0),
    TempoBand(label: "downtempo_soul", bpmMin: 60.0, bpmMax: 90.0, aslMin: 3.0, aslTarget: 4.0, aslMax: 5.0, hardCap: 8.0),
    TempoBand(label: "arthouse_slow", bpmMin: 0.0, bpmMax: 60.0, aslMin: 5.0, aslTarget: 6.5, aslMax: 8.0, hardCap: 12.0),
]

/// Return the matching `TempoBand` for a BPM value.
///
/// - Parameters:
///   - bpm: Perceived tempo (typically `Song.perceivedBpm`, not the raw
///     `bpm` value).
///   - mode: Optional shotlist mode (`beat` | `phrase` | `section` |
///     `multicam`). For `phrase` and `section` the ASL/hard-cap are relaxed
///     (1 shot per lyric phrase resp. section is deliberately longer than a
///     beat shot). For `beat`/`multicam` the standard band stays active.
///
/// Sentinel logic: at exactly 120 BPM `uptempo_dance` is chosen (>= bpmMin),
/// at 119.99 `midtempo_pop`. Port of `tempo.py::classify`.
public func classifyTempo(_ bpm: Double, mode: String? = nil) -> TempoBand {
    var base = tempoBands[2]  // Fallback
    for band in tempoBands where band.bpmMin <= bpm && bpm < band.bpmMax {
        base = band
        break
    }
    if mode == "phrase" || mode == "section" {
        // Mode-aware relaxation: 1 shot per phrase/section is by construction
        // longer than a beat shot. We scale ASL + cap.
        let scale = mode == "phrase" ? 2.5 : 4.0
        return TempoBand(
            label: "\(base.label)_\(mode!)",
            bpmMin: base.bpmMin, bpmMax: base.bpmMax,
            aslMin: base.aslMin * scale, aslTarget: base.aslTarget * scale, aslMax: base.aslMax * scale,
            hardCap: base.hardCap * scale
        )
    }
    return base
}

/// Aggregate ASL statistic for the sanity check. Port of `tempo.py::asl_violation`.
public struct ASLViolationStats: Sendable, Equatable {
    public let asl: Double
    public let target: Double
    public let aslMin: Double?
    public let aslMax: Double?
    public let hardCap: Double?
    public let overCapCount: Int
    public let overCapRatio: Double
    public let status: String

    public init(
        asl: Double, target: Double, aslMin: Double? = nil, aslMax: Double? = nil, hardCap: Double? = nil,
        overCapCount: Int, overCapRatio: Double, status: String
    ) {
        self.asl = asl
        self.target = target
        self.aslMin = aslMin
        self.aslMax = aslMax
        self.hardCap = hardCap
        self.overCapCount = overCapCount
        self.overCapRatio = overCapRatio
        self.status = status
    }
}

/// Port of `tempo.py::asl_violation`.
public func aslViolation(_ shotsDurationsS: [Double], band: TempoBand) -> ASLViolationStats {
    guard !shotsDurationsS.isEmpty else {
        return ASLViolationStats(asl: 0.0, target: band.aslTarget, overCapCount: 0, overCapRatio: 0.0, status: "ok")
    }
    let asl = shotsDurationsS.reduce(0, +) / Double(shotsDurationsS.count)
    let over = shotsDurationsS.filter { $0 > band.hardCap }
    let overRatio = Double(over.count) / Double(shotsDurationsS.count)
    var status = "ok"
    if overRatio >= 0.30 {
        status = "too_many_breakers"
    } else if asl > band.aslMax * 1.5 {
        status = "pacing_drift"
    }
    return ASLViolationStats(
        asl: (asl * 100).rounded() / 100,
        target: band.aslTarget,
        aslMin: band.aslMin,
        aslMax: band.aslMax,
        hardCap: band.hardCap,
        overCapCount: over.count,
        overCapRatio: (overRatio * 100).rounded() / 100,
        status: status
    )
}
