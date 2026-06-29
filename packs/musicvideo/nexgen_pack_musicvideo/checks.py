"""Music-specific sanity checks (tempo + pacing), ported into the pack.

These are pure read checks over the AuditContext: they look at the song's
perceived BPM and the shot durations / prompts and flag pacing problems. No
audio DSP, no disk reads — so no heavy deps.

BPM is sourced from `ctx.shotlist.song.perceived_bpm` (the engine Shotlist
carries the Song). For robustness the host/pack may instead hand the audio
Analysis in via `ctx.extra["analysis"]`; if neither yields a usable BPM the
checks return `[]` (cannot validate) rather than erroring.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from nexgen_engine.core.modes import Mode
from nexgen_engine.sanity.audit import AuditContext
from nexgen_engine.sanity.models import Finding

from nexgen_pack_musicvideo.tempo import TempoBand, asl_violation, classify


def _perceived_bpm(ctx: AuditContext) -> float:
    """Resolve perceived BPM. Prefer the shotlist's Song, fall back to an
    Analysis passed through `ctx.extra["analysis"]`. Returns 0.0 when no
    usable BPM is reachable."""
    song = getattr(ctx.shotlist, "song", None)
    if song is not None:
        bpm = getattr(song, "perceived_bpm", None) or getattr(song, "bpm", None)
        if bpm:
            return float(bpm)

    extra = ctx.extra or {}
    analysis = extra.get("analysis")
    if analysis is not None:
        bpm = (
            getattr(analysis, "perceived_bpm", None)
            or getattr(analysis, "bpm", None)
        )
        if bpm:
            return float(bpm)

    return 0.0


def _mode_value(ctx: AuditContext) -> str | None:
    mode = getattr(ctx.shotlist, "mode", None)
    return getattr(mode, "value", mode)


def tempo(ctx: AuditContext) -> list[Finding]:
    """Tempo-pacing check: ASL drift + per-shot hard-cap (ported from
    musicvideo `sanity/checks/tempo.py`).

    Multicam has no per-shot pacing (one camera spans the whole song), so it
    is skipped. If BPM is unavailable we cannot classify a tempo band and
    return no findings.
    """
    out: list[Finding] = []
    if _mode_value(ctx) == Mode.MULTICAM.value:
        return out

    bpm = _perceived_bpm(ctx)
    if bpm <= 0:
        return out

    band = classify(bpm, mode=_mode_value(ctx))
    durations = [s.duration_s for s in ctx.shotlist.shots]
    stats = asl_violation(durations, band)

    for s in ctx.shotlist.shots:
        if s.duration_s > band.hard_cap:
            out.append(
                Finding(
                    "warn",
                    "SHOT_OVER_TEMPO_CAP",
                    s.id,
                    f"{s.duration_s:.1f}s over hard_cap {band.hard_cap:.1f}s "
                    f"({band.label}, BPM {bpm:.1f}). "
                    f"Deliberate breaker or split the phrase?",
                )
            )

    if stats["status"] == "too_many_breakers":
        out.append(
            Finding(
                "warn",
                "PACING_TOO_MANY_BREAKERS",
                None,
                f"{stats['over_cap_count']} of {len(durations)} shots "
                f"over hard_cap ({stats['over_cap_ratio']:.0%}). "
                f"Tempo band {band.label} expects ASL "
                f"{band.asl_min}-{band.asl_max}s, here {stats['asl']:.1f}s. "
                f"Long phrases should be split into more shots.",
            )
        )
    elif stats["status"] == "pacing_drift":
        out.append(
            Finding(
                "warn",
                "PACING_DRIFT",
                None,
                f"ASL {stats['asl']:.1f}s well above tempo-band maximum "
                f"{band.asl_max}s ({band.label}, BPM {bpm:.1f}). "
                f"Video likely feels too sluggish.",
            )
        )
    return out


# ----- Shot-pacing plausibility ---------------------------------------------
#
# Estimates the action-beat density per shot from visual_prompt + motion +
# character_blocking poses and compares it against `duration_s`. Bidirectional:
# too few beats over a long clip = slow-motion risk; too many beats over a
# short clip = rushed/jitter risk.

LOW_DENSITY_SECONDS_PER_BEAT = 4.0
HIGH_DENSITY_BEATS_PER_SECOND = 0.9
MIN_DURATION_FOR_LOW_DENSITY_CHECK = 5.0
MIN_BEATS_FOR_HIGH_DENSITY_CHECK = 3

# Action verbs with a movement character. Inflection -> lemma so "reaches" and
# "reach" count as ONE beat. Deliberately small and conservative.
_VERB_LEMMAS: dict[str, str] = {
    "reach": "reach", "reaches": "reach",
    "grab": "grab", "grabs": "grab",
    "pick": "pick", "picks": "pick",
    "lift": "lift", "lifts": "lift",
    "place": "place", "places": "place",
    "put": "put", "puts": "put",
    "drop": "drop", "drops": "drop",
    "throw": "throw", "throws": "throw",
    "catch": "catch", "catches": "catch",
    "hold": "hold", "holds": "hold",
    "pull": "pull", "pulls": "pull",
    "push": "push", "pushes": "push",
    "press": "press", "presses": "press",
    "tap": "tap", "taps": "tap",
    "type": "type", "types": "type",
    "write": "write", "writes": "write",
    "draw": "draw", "draws": "draw",
    "tear": "tear", "tears": "tear",
    "rip": "rip", "rips": "rip",
    "open": "open", "opens": "open",
    "close": "close", "closes": "close",
    "unroll": "unroll", "unrolls": "unroll",
    "fold": "fold", "folds": "fold",
    "unfold": "unfold", "unfolds": "unfold",
    "wrap": "wrap", "wraps": "wrap",
    "raise": "raise", "raises": "raise",
    "lower": "lower", "lowers": "lower",
    "swing": "swing", "swings": "swing",
    "gesture": "gesture", "gestures": "gesture",
    "slide": "slide", "slides": "slide",
    "read": "read", "reads": "read",
    "speak": "speak", "speaks": "speak",
    "say": "say", "says": "say",
    "shout": "shout", "shouts": "shout",
    "whisper": "whisper", "whispers": "whisper",
    "nod": "nod", "nods": "nod",
    "shake": "shake", "shakes": "shake",
    "smile": "smile", "smiles": "smile",
    "frown": "frown", "frowns": "frown",
    "wink": "wink", "winks": "wink",
    "blink": "blink", "blinks": "blink",
    "yawn": "yawn", "yawns": "yawn",
    "look": "look", "looks": "look",
    "glance": "glance", "glances": "glance",
    "stand": "stand", "stands": "stand",
    "sit": "sit", "sits": "sit",
    "kneel": "kneel", "kneels": "kneel",
    "lean": "lean", "leans": "lean",
    "turn": "turn", "turns": "turn",
    "spin": "spin", "spins": "spin",
    "twist": "twist", "twists": "twist",
    "bend": "bend", "bends": "bend",
    "stretch": "stretch", "stretches": "stretch",
    "crouch": "crouch", "crouches": "crouch",
    "tilt": "tilt", "tilts": "tilt",
    "step": "step", "steps": "step",
    "walk": "walk", "walks": "walk",
    "run": "run", "runs": "run",
    "jump": "jump", "jumps": "jump",
    "land": "land", "lands": "land",
    "rise": "rise", "rises": "rise",
    "climb": "climb", "climbs": "climb",
    "enter": "enter", "enters": "enter",
    "exit": "exit", "exits": "exit",
    "leave": "leave", "leaves": "leave",
    "arrive": "arrive", "arrives": "arrive",
    "appear": "appear", "appears": "appear",
    "vanish": "vanish", "vanishes": "vanish",
    "emerge": "emerge", "emerges": "emerge",
    "approach": "approach", "approaches": "approach",
    "pass": "pass", "passes": "pass",
    "give": "give", "gives": "give",
    "show": "show", "shows": "show",
    "point": "point", "points": "point",
    "wave": "wave", "waves": "wave",
    "hug": "hug", "hugs": "hug",
    "kiss": "kiss", "kisses": "kiss",
    "punch": "punch", "punches": "punch",
    "kick": "kick", "kicks": "kick",
    "strike": "strike", "strikes": "strike",
}

_VERB_PATTERN = re.compile(
    r"\b(" + "|".join(sorted(_VERB_LEMMAS.keys(), key=len, reverse=True)) + r")\b",
    re.IGNORECASE,
)

_SEQUENCE_CONNECTORS = re.compile(
    r"\b(then|after that|next|finally|before)\b",
    re.IGNORECASE,
)

_PACING_OK_MARKER = re.compile(r"\bpacing_ok\s*:", re.IGNORECASE)


@dataclass(frozen=True)
class PacingHit:
    code: str
    direction: str
    duration_s: float
    beats: int
    seconds_per_beat: float
    beats_per_second: float
    message: str


def _is_pacing_marked(notes: str | None) -> bool:
    return bool(notes) and bool(_PACING_OK_MARKER.search(notes))


def count_action_beats(
    visual_prompt: str | None,
    motion: str | None,
    blocking_text: str | None,
) -> int:
    """Rough count of distinct action beats from the prompt fields. Lemma-dedup:
    "reaches" and "reach" count as ONE beat. Sequence connectors ("then", ...)
    count extra because they signal an explicit timeline."""
    text = " ".join(t for t in (visual_prompt, motion, blocking_text) if t)
    if not text.strip():
        return 0
    verb_lemmas = {
        _VERB_LEMMAS[m.group(0).lower()]
        for m in _VERB_PATTERN.finditer(text)
        if m.group(0).lower() in _VERB_LEMMAS
    }
    seq_hits = len(_SEQUENCE_CONNECTORS.findall(text))
    return len(verb_lemmas) + seq_hits


def _check_shot(
    shot_id: str,
    duration_s: float,
    visual_prompt: str | None,
    motion: str | None,
    blocking_text: str | None,
    notes: str | None,
) -> list[PacingHit]:
    """Evaluate pacing for one shot. Returns 0..1 PacingHit."""
    if _is_pacing_marked(notes):
        return []
    if duration_s <= 0:
        return []

    beats = count_action_beats(visual_prompt, motion, blocking_text)

    if duration_s >= MIN_DURATION_FOR_LOW_DENSITY_CHECK:
        effective_beats = max(beats, 1)
        spb = duration_s / effective_beats
        if spb > LOW_DENSITY_SECONDS_PER_BEAT:
            return [
                PacingHit(
                    code="SHOT_PACING_IMPLAUSIBLE",
                    direction="slow_motion_risk",
                    duration_s=duration_s,
                    beats=beats,
                    seconds_per_beat=spb,
                    beats_per_second=beats / duration_s if duration_s else 0.0,
                    message=(
                        f"Shot {shot_id} ({duration_s:.1f}s) has only ~{beats} "
                        f"action beat(s) in the prompt — {spb:.1f}s per beat. "
                        "The video model tends to stretch the single action "
                        "(looks like slow-motion). Fix: (a) specify more "
                        "distinct action beats in visual_prompt / motion / "
                        "character_blocking ('then X, then Y'-mini-timeline), "
                        "or (b) accept deliberate idle bracketing. If the "
                        "stillness is intended: `pacing_ok: <reason>` in "
                        "Shot.notes."
                    ),
                )
            ]

    if beats >= MIN_BEATS_FOR_HIGH_DENSITY_CHECK and duration_s > 0:
        bps = beats / duration_s
        if bps >= HIGH_DENSITY_BEATS_PER_SECOND:
            return [
                PacingHit(
                    code="SHOT_PACING_IMPLAUSIBLE",
                    direction="rushed_risk",
                    duration_s=duration_s,
                    beats=beats,
                    seconds_per_beat=duration_s / beats if beats else 0.0,
                    beats_per_second=bps,
                    message=(
                        f"Shot {shot_id} ({duration_s:.1f}s) packs ~{beats} "
                        f"action beats — {bps:.2f} beats/s. The video model "
                        "tends to jitter or skip beats. Fix: (a) split the "
                        "shot in two, or (b) reduce beats to the core action. "
                        "If intended: `pacing_ok: <reason>` in Shot.notes."
                    ),
                )
            ]

    return []


def _blocking_text(shot: object) -> str | None:
    """Concatenate character_blocking fields (pose, gaze, position,
    relation_to_set) into a beat-source text. Pose verbs otherwise live only
    in this struct and would not feed the beat count."""
    blocking = getattr(shot, "character_blocking", None)
    if not blocking:
        return None
    parts: list[str] = []
    for b in blocking:
        for field_name in ("pose", "gaze", "position", "relation_to_set"):
            val = getattr(b, field_name, None)
            if isinstance(val, str) and val.strip():
                parts.append(val.strip())
    return " ".join(parts) if parts else None


def pacing(ctx: AuditContext) -> list[Finding]:
    """Shot-pacing plausibility.

    Flags SHOT_PACING_IMPLAUSIBLE per shot, bidirectional (slow-motion vs
    rushed). Reads only prompt fields, no BPM needed.
    """
    out: list[Finding] = []
    for shot in ctx.shotlist.shots:
        hits = _check_shot(
            shot.id,
            duration_s=float(shot.duration_s or 0.0),
            visual_prompt=shot.visual_prompt,
            motion=getattr(shot, "motion", None),
            blocking_text=_blocking_text(shot),
            notes=shot.notes,
        )
        for hit in hits:
            out.append(Finding("warn", hit.code, shot.id, hit.message))
    return out
