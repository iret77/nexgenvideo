"""Downbeat-Detection mit madmom (primär) oder librosa-Heuristik (Fallback).

madmom ist optional. Bei Installationsproblemen fällt der Analyse-Lauf
automatisch auf die 4/4-Heuristik zurück und markiert das in analysis.json
unter downbeat_source.
"""

from __future__ import annotations

from pathlib import Path
from typing import Literal

from nexgen_pack_musicvideo.analysis.audio import LoadedAudio

DownbeatSource = Literal["madmom", "librosa-heuristic"]


def detect(audio: LoadedAudio, audio_path: Path, beats: list[float]) -> tuple[list[float], DownbeatSource]:
    """Return (downbeat_times, source_label)."""
    try:
        return _madmom_downbeats(audio_path), "madmom"
    except Exception:
        return _librosa_heuristic(beats), "librosa-heuristic"


def _madmom_downbeats(audio_path: Path) -> list[float]:
    # Import lazy, damit madmom-Abwesenheit kein Blocker ist.
    from madmom.features.beats import RNNBeatProcessor  # type: ignore
    from madmom.features.downbeats import (  # type: ignore
        DBNDownBeatTrackingProcessor,
        RNNDownBeatProcessor,
    )

    # madmom benötigt einen String-Pfad
    rnn = RNNDownBeatProcessor()
    proc = DBNDownBeatTrackingProcessor(beats_per_bar=[3, 4], fps=100)
    _ = RNNBeatProcessor  # explizit referenziert, falls madmom das erwartet
    activations = rnn(str(audio_path))
    beats_array = proc(activations)  # shape (N, 2): [time, beat_in_bar]
    return [float(t) for t, pos in beats_array if int(pos) == 1]


def _librosa_heuristic(beats: list[float], beats_per_bar: int = 4) -> list[float]:
    """Fallback: jeder N-te Beat als Downbeat. Annahme 4/4."""
    if not beats:
        return []
    return [beats[i] for i in range(0, len(beats), beats_per_bar)]
