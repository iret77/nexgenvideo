"""Librosa-basierte Audio-Analyse: Load, Tempo, Beats."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import librosa
import numpy as np


@dataclass
class LoadedAudio:
    y: np.ndarray
    sr: int
    duration_s: float


def load(path: Path, sr: int | None = 22050) -> LoadedAudio:
    y, sr_out = librosa.load(str(path), sr=sr, mono=True)
    return LoadedAudio(y=y, sr=int(sr_out), duration_s=float(librosa.get_duration(y=y, sr=sr_out)))


def estimate_tempo_and_beats(audio: LoadedAudio) -> tuple[float, list[float]]:
    """Return (bpm, beat_times_seconds).

    BPM aus Median der tatsächlichen Beat-Intervalle ist robuster als der
    aggregierte Wert von librosa.beat.beat_track, der bei manchen Songs
    1-2 % danebenliegt.
    """
    _, beat_frames = librosa.beat.beat_track(y=audio.y, sr=audio.sr, units="frames")
    beat_times = librosa.frames_to_time(beat_frames, sr=audio.sr)
    if len(beat_times) < 2:
        return 0.0, [float(t) for t in beat_times]
    intervals = np.diff(beat_times)
    median_interval = float(np.median(intervals))
    bpm = 60.0 / median_interval if median_interval > 0 else 0.0
    return bpm, [float(t) for t in beat_times]
