"""Tests for the ported tempo + pacing sanity checks."""

from __future__ import annotations

import pytest

from nexgen_engine.core.modes import Mode
from nexgen_engine.sanity.audit import AuditContext
from nexgen_engine.shotlist.schema import (
    SCHEMA_VERSION,
    Shot,
    Shotlist,
    ShotType,
    Song,
)

from nexgen_pack_musicvideo.checks import pacing, tempo


def _song(bpm: float = 128.0, tempo_multiplier: float = 1.0) -> Song:
    return Song(
        title="t",
        audio_path="audio/song.wav",
        analysis_path="analysis/song.json",
        bpm=bpm,
        tempo_multiplier=tempo_multiplier,
        duration_s=180.0,
    )


def _shot(idx: int, *, duration: float, visual_prompt: str = "a calm wide vista", motion: str | None = None, notes: str | None = None) -> Shot:
    start = float(idx) * 100.0
    return Shot(
        id=f"s{idx:03d}",
        section="verse",
        time_start=start,
        time_end=start + duration,
        duration_s=duration,
        type=ShotType.PERFORMANCE,
        description="d",
        visual_prompt=visual_prompt,
        motion=motion,
        mood="m",
        notes=notes,
    )


def _shotlist(shots: list[Shot], *, song: Song | None = None, mode: Mode = Mode.BEAT) -> Shotlist:
    return Shotlist(
        **{"schema": SCHEMA_VERSION},
        mode=mode,
        project="proj",
        song=song if song is not None else _song(),
        generated="2026-01-01",
        generator="test",
        shots=shots,
    )


def _ctx(shotlist: Shotlist, *, extra: dict | None = None) -> AuditContext:
    return AuditContext(shotlist=shotlist, extra=extra)


# ----- tempo -----------------------------------------------------------------

def test_tempo_flags_shots_over_hard_cap_at_uptempo():
    # uptempo_dance hard_cap = 4.0s; two shots at 8s blow past it.
    shots = [_shot(1, duration=8.0), _shot(2, duration=8.0)]
    findings = tempo(_ctx(_shotlist(shots, song=_song(bpm=128.0))))
    codes = {f.code for f in findings}
    assert "SHOT_OVER_TEMPO_CAP" in codes
    # 2/2 shots over cap => too_many_breakers
    assert "PACING_TOO_MANY_BREAKERS" in codes
    over_cap = [f for f in findings if f.code == "SHOT_OVER_TEMPO_CAP"]
    assert {f.shot_id for f in over_cap} == {"s001", "s002"}
    assert all(f.level == "warn" for f in findings)


def test_tempo_clean_when_durations_match_band():
    shots = [_shot(1, duration=1.5), _shot(2, duration=2.0), _shot(3, duration=1.5)]
    findings = tempo(_ctx(_shotlist(shots, song=_song(bpm=128.0))))
    assert findings == []


def test_tempo_returns_empty_when_bpm_unavailable():
    # Build a shotlist, then null out the song's bpm so no band can be derived.
    shots = [_shot(1, duration=8.0), _shot(2, duration=8.0)]
    sl = _shotlist(shots, song=_song(bpm=128.0))
    object.__setattr__(sl.song, "bpm", 0.0)
    object.__setattr__(sl.song, "tempo_multiplier", 0.0)
    findings = tempo(_ctx(sl))
    assert findings == []


def test_tempo_skips_multicam():
    # Multicam shots span the whole song; build a valid multicam shotlist.
    song = _song(bpm=128.0)
    shot = Shot(
        id="s001",
        time_start=0.0,
        time_end=song.duration_s,
        duration_s=song.duration_s,
        type=ShotType.PERFORMANCE,
        description="d",
        visual_prompt="performance",
        mood="m",
        camera_id="cam01",
    )
    sl = _shotlist([shot], song=song, mode=Mode.MULTICAM)
    assert tempo(_ctx(sl)) == []


def test_tempo_bpm_from_extra_analysis_when_song_has_none():
    shots = [_shot(1, duration=8.0), _shot(2, duration=8.0)]
    sl = _shotlist(shots, song=_song(bpm=128.0))
    object.__setattr__(sl.song, "bpm", 0.0)
    object.__setattr__(sl.song, "tempo_multiplier", 0.0)

    class _Analysis:
        perceived_bpm = 128.0

    findings = tempo(_ctx(sl, extra={"analysis": _Analysis()}))
    assert any(f.code == "SHOT_OVER_TEMPO_CAP" for f in findings)


# ----- pacing ----------------------------------------------------------------

def test_pacing_flags_slow_motion_risk():
    # 1 action beat ("sits") over a 12s clip => 12s/beat > 4.0 threshold.
    shots = [_shot(1, duration=12.0, visual_prompt="sits at the desk, papers in front")]
    findings = pacing(_ctx(_shotlist(shots)))
    assert len(findings) == 1
    assert findings[0].code == "SHOT_PACING_IMPLAUSIBLE"
    assert findings[0].shot_id == "s001"
    assert findings[0].level == "warn"


def test_pacing_clean_when_density_matches_duration():
    # 3 beats over 12s => 4.0s/beat exactly (not > 4.0) and 0.25 b/s => clean.
    shots = [
        _shot(
            1,
            duration=12.0,
            visual_prompt="she stands, then turns, then walks toward the door",
        )
    ]
    findings = pacing(_ctx(_shotlist(shots)))
    assert findings == []


def test_pacing_silenced_by_marker():
    shots = [
        _shot(
            1,
            duration=12.0,
            visual_prompt="sits at the desk",
            notes="pacing_ok: intentional contemplative still life",
        )
    ]
    assert pacing(_ctx(_shotlist(shots))) == []
