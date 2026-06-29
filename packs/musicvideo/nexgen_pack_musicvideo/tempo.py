"""Tempo-dependent shot-pacing guidance.

Music videos have decades-grown ASL conventions (Average Shot Length)
per tempo class. Ignoring them produces videos that simply feel wrong —
too sluggish on uptempo, choppy on a ballad.

Sources / viewing habit:
- Uptempo (120+ BPM): 1-2 s ASL, outliers max ~4 s
- Mid-tempo Pop/Rock (90-120 BPM): 2-4 s, max ~6 s
- Downtempo / Soul / Ballad (60-90 BPM): 3-5 s, max ~8 s
- Very slow / Arthouse (<60 BPM): 5-8 s, max ~12 s

The `hard_cap` is the threshold above which a shot is structurally
suspect — either a deliberate breaker (outro hold, bridge negative
space) or the pacing is drifting off. Sanity flags when >=30 % of the
shots exceed `hard_cap`.

In phrase mode, lyric phrases often have natural lengths above the
target — the fix is not to shorten the phrase artificially, but to
split long phrases into 2-4 shots.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TempoBand:
    label: str
    bpm_min: float       # inclusive
    bpm_max: float       # exclusive — last band's max is sentinel
    asl_min: float       # lower bound of typical ASL in seconds
    asl_target: float    # preferred middle
    asl_max: float       # upper bound of typical ASL
    hard_cap: float      # absolute max for a single shot — above this a breaker

    def describe(self) -> str:
        """Short, direction-ready description for prompt injection."""
        return (
            f"{self.label} ({self.bpm_min:.0f}-{self.bpm_max:.0f} BPM): "
            f"ASL {self.asl_min:.0f}-{self.asl_max:.0f} s "
            f"(target ~{self.asl_target:.0f} s), "
            f"single shots at most ~{self.hard_cap:.0f} s"
        )


TEMPO_BANDS: tuple[TempoBand, ...] = (
    TempoBand("uptempo_dance",   bpm_min=120.0, bpm_max=999.0,
              asl_min=1.0, asl_target=1.5, asl_max=2.0, hard_cap=4.0),
    TempoBand("midtempo_pop",    bpm_min=90.0,  bpm_max=120.0,
              asl_min=2.0, asl_target=3.0, asl_max=4.0, hard_cap=6.0),
    TempoBand("downtempo_soul",  bpm_min=60.0,  bpm_max=90.0,
              asl_min=3.0, asl_target=4.0, asl_max=5.0, hard_cap=8.0),
    TempoBand("arthouse_slow",   bpm_min=0.0,   bpm_max=60.0,
              asl_min=5.0, asl_target=6.5, asl_max=8.0, hard_cap=12.0),
)


def classify(bpm: float, mode: str | None = None) -> TempoBand:
    """Return the matching TempoBand for a BPM value.

    Args:
        bpm: Perceived tempo (typically `analysis.perceived_bpm`, not the
            raw `bpm` value — see Analysis.tempo_multiplier).
        mode: Optional, shotlist mode (`beat` | `phrase` | `section` |
            `multicam`). For `phrase` and `section` the ASL/hard-cap are
            relaxed (1 shot per lyric phrase resp. section is deliberately
            longer than a beat shot). For `beat`/`multicam` the standard
            band stays active.

    Sentinel logic: At exactly 120 BPM `uptempo_dance` is chosen
    (>= bpm_min), at 119.99 `midtempo_pop`. Edge cases at the boundary
    are irrelevant in practice — the bands overlap psychologically.
    """
    base = TEMPO_BANDS[2]  # Fallback
    for band in TEMPO_BANDS:
        if band.bpm_min <= bpm < band.bpm_max:
            base = band
            break
    if mode in {"phrase", "section"}:
        # Mode-aware relaxation: 1 shot per phrase/section is by construction
        # longer than a beat shot. We scale ASL + cap.
        scale = 2.5 if mode == "phrase" else 4.0
        return TempoBand(
            label=f"{base.label}_{mode}",
            bpm_min=base.bpm_min, bpm_max=base.bpm_max,
            asl_min=base.asl_min * scale,
            asl_target=base.asl_target * scale,
            asl_max=base.asl_max * scale,
            hard_cap=base.hard_cap * scale,
        )
    return base


def asl_violation(shots_durations_s: list[float], band: TempoBand) -> dict:
    """Aggregate statistic for the sanity check.

    Returns:
        dict with:
        - asl: computed ASL of the shotlist
        - target: target ASL of the band
        - over_cap_count: shots > hard_cap
        - over_cap_ratio: over hard_cap as a fraction
        - status: 'ok' | 'pacing_drift' | 'too_many_breakers'
    """
    if not shots_durations_s:
        return {"asl": 0.0, "target": band.asl_target,
                "over_cap_count": 0, "over_cap_ratio": 0.0, "status": "ok"}
    asl = sum(shots_durations_s) / len(shots_durations_s)
    over = [d for d in shots_durations_s if d > band.hard_cap]
    over_ratio = len(over) / len(shots_durations_s)
    status = "ok"
    if over_ratio >= 0.30:
        status = "too_many_breakers"
    elif asl > band.asl_max * 1.5:
        status = "pacing_drift"
    return {
        "asl": round(asl, 2),
        "target": band.asl_target,
        "asl_min": band.asl_min,
        "asl_max": band.asl_max,
        "hard_cap": band.hard_cap,
        "over_cap_count": len(over),
        "over_cap_ratio": round(over_ratio, 2),
        "status": status,
    }
