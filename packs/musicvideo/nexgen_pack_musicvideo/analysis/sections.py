"""Struktur-Segmentierung via librosa laplacian segmentation + KMeans.

Liefert roh-segmentierte Sections (Index, Start, Ende, Cluster-ID).
Narrative Labels werden vom analysis-agent nachträglich gesetzt.
"""

from __future__ import annotations

from dataclasses import dataclass

import librosa
import numpy as np
from sklearn.cluster import KMeans

from nexgen_pack_musicvideo.analysis.audio import LoadedAudio


@dataclass
class RawSection:
    index: int
    start: float
    end: float
    cluster: int


def segment(audio: LoadedAudio, n_clusters: int = 4, min_section_s: float = 4.0) -> list[RawSection]:
    """Grobe strukturelle Segmentierung. n_clusters = typische Section-Typen (intro/verse/chorus/bridge)."""
    y, sr = audio.y, audio.sr

    # Chroma + MFCC als Features für recurrence + segmentation
    hop_length = 512
    chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop_length)
    mfcc = librosa.feature.mfcc(y=y, sr=sr, hop_length=hop_length, n_mfcc=13)
    features = np.vstack([chroma, mfcc])

    # Beat-sync, damit Segmentgrenzen auf Beats liegen
    _, beats = librosa.beat.beat_track(y=y, sr=sr, hop_length=hop_length)
    if len(beats) < max(n_clusters * 2, 8):
        # Zu wenig Beats für sinnvolle Segmentierung — ganze Datei als eine Section
        return [RawSection(index=0, start=0.0, end=audio.duration_s, cluster=0)]

    beat_features = librosa.util.sync(features, beats, aggregate=np.mean)
    beat_times = librosa.frames_to_time(beats, sr=sr, hop_length=hop_length).tolist()
    beat_times = [0.0] + beat_times + [audio.duration_s]

    # Cluster auf Beat-Features
    n_samples = beat_features.shape[1]
    k = min(n_clusters, max(2, n_samples // 2))
    km = KMeans(n_clusters=k, n_init="auto", random_state=0)
    labels = km.fit_predict(beat_features.T)

    # Grenzen da, wo Cluster wechselt
    sections: list[RawSection] = []
    start_idx = 0
    current_cluster = int(labels[0])
    for i in range(1, len(labels)):
        if int(labels[i]) != current_cluster:
            sections.append(
                RawSection(
                    index=len(sections),
                    start=float(beat_times[start_idx]),
                    end=float(beat_times[i]),
                    cluster=current_cluster,
                )
            )
            start_idx = i
            current_cluster = int(labels[i])
    sections.append(
        RawSection(
            index=len(sections),
            start=float(beat_times[start_idx]),
            end=float(audio.duration_s),
            cluster=current_cluster,
        )
    )

    # Kurze Sections in den Nachbarn verschmelzen
    merged: list[RawSection] = []
    for sec in sections:
        if merged and (sec.end - sec.start) < min_section_s:
            merged[-1] = RawSection(
                index=merged[-1].index,
                start=merged[-1].start,
                end=sec.end,
                cluster=merged[-1].cluster,
            )
        else:
            merged.append(sec)
    for i, s in enumerate(merged):
        merged[i] = RawSection(index=i, start=s.start, end=s.end, cluster=s.cluster)
    return merged
