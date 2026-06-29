"""Essentia-basierte Structure-Detection.

Nutzt SBic (Bayesian Information Criterion Segmentation) auf MFCC-Features
der Audio-Datei. Präziser als librosa-Laplacian bei klaren musikalischen
Übergängen, aber abhängig von Feature-Setup.

Import von Essentia ist lazy — wenn das Paket nicht installiert ist,
wird `available()` False.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from nexgen_pack_musicvideo.analysis_schema import Section


def available() -> bool:
    try:
        import essentia.standard  # noqa: F401
        return True
    except Exception:
        return False


class EssentiaDetector:
    name = "essentia"

    def __init__(self, min_section_s: float = 6.0) -> None:
        self.min_section_s = min_section_s

    def detect(self, audio_path: Path, duration_s: float) -> list[Section]:
        import essentia.standard as es  # type: ignore

        loader = es.MonoLoader(filename=str(audio_path), sampleRate=22050)
        audio = loader()

        # MFCC-Feature-Matrix für SBic.
        frame_size = 2048
        hop_size = 1024
        frames = es.FrameGenerator(audio, frameSize=frame_size, hopSize=hop_size, startFromZero=True)
        w = es.Windowing(type="hann")
        spectrum = es.Spectrum()
        mfcc = es.MFCC(numberCoefficients=13)

        mfccs: list[np.ndarray] = []
        for frame in frames:
            _, coeffs = mfcc(spectrum(w(frame)))
            mfccs.append(np.asarray(coeffs, dtype=np.float32))

        if not mfccs:
            return [Section(index=0, start=0.0, end=duration_s, cluster=0, source=self.name)]

        feat = np.stack(mfccs, axis=1)  # shape (ncoeffs, nframes)

        # SBic: Bayesian Information Criterion basierte Segmentierung
        sbic = es.SBic()
        seg = sbic(feat)  # array of frame-indices where a segment boundary is detected

        frame_to_time = hop_size / 22050.0
        boundaries_s = [float(f) * frame_to_time for f in seg]
        # ensure start/end
        boundaries_s = sorted({0.0, *boundaries_s, duration_s})

        raw: list[Section] = []
        for i, (a, b) in enumerate(zip(boundaries_s, boundaries_s[1:], strict=False)):
            raw.append(Section(index=i, start=round(a, 3), end=round(b, 3), cluster=i, source=self.name))

        # Merge zu kurze Sections
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
        return merged or [Section(index=0, start=0.0, end=duration_s, cluster=0, source=self.name)]
