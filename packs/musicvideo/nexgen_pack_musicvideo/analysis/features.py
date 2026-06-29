"""Zusatz-Features: Energy-Curve, Tempo-Curve, Key, Chord-Progression.

Energy + Tempo: librosa (leicht, schnell).
Key: essentia (bei Vorhandensein), sonst madmom-Fallback, sonst None.
Chord: madmom deep chroma chord recognition (optional, wird vom Brief
abgefragt).
"""

from __future__ import annotations

from pathlib import Path

import librosa
import numpy as np

from nexgen_pack_musicvideo.analysis_schema import Chord, EnergyPoint, TempoPoint


def energy_curve(audio_path: Path, hop_ms: int = 100) -> list[EnergyPoint]:
    """RMS-Energy, gesampelt auf `hop_ms`."""
    y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
    frame_length = 2048
    hop_length = int(sr * hop_ms / 1000.0)
    rms = librosa.feature.rms(y=y, frame_length=frame_length, hop_length=hop_length)[0]
    max_rms = float(rms.max()) if len(rms) else 1.0
    norm = rms / max_rms if max_rms > 0 else rms
    times = librosa.frames_to_time(range(len(rms)), sr=sr, hop_length=hop_length)
    return [
        EnergyPoint(t=round(float(t), 3), rms=round(float(v), 4))
        for t, v in zip(times, norm, strict=False)
    ]


def tempo_curve(audio_path: Path, hop_s: float = 2.0) -> list[TempoPoint]:
    """Lokales Tempo in Fenster-Samples — statt nur globalem BPM."""
    y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
    onset_env = librosa.onset.onset_strength(y=y, sr=sr)
    hop_length = 512
    tempo_per_frame = librosa.beat.tempo(
        onset_envelope=onset_env,
        sr=sr,
        aggregate=None,
        hop_length=hop_length,
    )
    frame_times = librosa.frames_to_time(range(len(tempo_per_frame)), sr=sr, hop_length=hop_length)
    # Downsample auf hop_s
    step = max(1, int(hop_s * sr / hop_length))
    out: list[TempoPoint] = []
    for i in range(0, len(tempo_per_frame), step):
        out.append(
            TempoPoint(t=round(float(frame_times[i]), 3), bpm=round(float(tempo_per_frame[i]), 2))
        )
    return out


def key_essentia(audio_path: Path) -> str | None:
    """Key-Detection via Essentia KeyExtractor. None, falls Essentia nicht da."""
    try:
        import essentia.standard as es  # type: ignore
    except Exception:
        return None
    loader = es.MonoLoader(filename=str(audio_path), sampleRate=22050)
    audio = loader()
    key_extractor = es.KeyExtractor()
    key, scale, _strength = key_extractor(audio)
    return f"{key} {scale}"


def chord_progression(audio_path: Path) -> list[Chord]:
    """Chord-Progression via madmom deep chroma chord recognition.

    Rückgabe: leere Liste, wenn madmom nicht verfügbar oder Recognition fehlschlägt.
    """
    try:
        from madmom.features.chords import (  # type: ignore
            CNNChordFeatureProcessor,
            CRFChordRecognitionProcessor,
        )
    except Exception:
        return []

    try:
        features_proc = CNNChordFeatureProcessor()
        decode_proc = CRFChordRecognitionProcessor()
        features = features_proc(str(audio_path))
        chords = decode_proc(features)
    except Exception:
        return []

    out: list[Chord] = []
    for start, end, label in chords:
        if label == "N":  # no-chord
            continue
        out.append(Chord(start=round(float(start), 3), end=round(float(end), 3), label=str(label)))
    return out


def global_bpm_from_downbeats(downbeats: list[float], beats_per_bar: int = 4) -> float:
    """Stabilster globaler BPM: Median der Downbeat-Intervalle × beats_per_bar."""
    if len(downbeats) < 3:
        return 0.0
    intervals = np.diff(downbeats)
    median = float(np.median(intervals))
    if median <= 0:
        return 0.0
    return round(60.0 * beats_per_bar / median, 3)
