"""Librosa-Fallback für Structure-Detection.

Nutzt Laplacian-Segmentation auf Chroma+MFCC. Robust, aber grob.
"""

from __future__ import annotations

from pathlib import Path

import librosa
import numpy as np
from sklearn.cluster import KMeans

from nexgen_pack_musicvideo.analysis_schema import Section


class LibrosaDetector:
    name = "librosa"

    def __init__(self, n_clusters: int = 5, min_section_s: float = 6.0) -> None:
        self.n_clusters = n_clusters
        self.min_section_s = min_section_s

    def detect(self, audio_path: Path, duration_s: float) -> list[Section]:
        y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
        hop = 512

        chroma = librosa.feature.chroma_cqt(y=y, sr=sr, hop_length=hop)
        mfcc = librosa.feature.mfcc(y=y, sr=sr, hop_length=hop, n_mfcc=13)
        features = np.vstack([chroma, mfcc])

        _, beats = librosa.beat.beat_track(y=y, sr=sr, hop_length=hop)
        if len(beats) < max(self.n_clusters * 2, 8):
            return [Section(index=0, start=0.0, end=duration_s, cluster=0, source=self.name)]

        beat_features = librosa.util.sync(features, beats, aggregate=np.mean)
        beat_times = librosa.frames_to_time(beats, sr=sr, hop_length=hop).tolist()
        beat_times = [0.0] + beat_times + [duration_s]

        n_samples = beat_features.shape[1]
        k = min(self.n_clusters, max(2, n_samples // 2))
        km = KMeans(n_clusters=k, n_init="auto", random_state=0)
        labels = km.fit_predict(beat_features.T)

        raw: list[Section] = []
        start_idx = 0
        current_cluster = int(labels[0])
        for i in range(1, len(labels)):
            if int(labels[i]) != current_cluster:
                raw.append(
                    Section(
                        index=len(raw),
                        start=float(beat_times[start_idx]),
                        end=float(beat_times[i]),
                        cluster=current_cluster,
                        source=self.name,
                    )
                )
                start_idx = i
                current_cluster = int(labels[i])
        raw.append(
            Section(
                index=len(raw),
                start=float(beat_times[start_idx]),
                end=duration_s,
                cluster=current_cluster,
                source=self.name,
            )
        )

        # Merge zu kurze Sections in den Vorgänger
        merged: list[Section] = []
        for sec in raw:
            if merged and (sec.end - sec.start) < self.min_section_s:
                merged[-1] = Section(
                    index=merged[-1].index,
                    start=merged[-1].start,
                    end=sec.end,
                    cluster=merged[-1].cluster,
                    source=self.name,
                )
            else:
                merged.append(sec)
        for i, s in enumerate(merged):
            merged[i] = Section(
                index=i, start=s.start, end=s.end, cluster=s.cluster, source=self.name
            )
        return merged
