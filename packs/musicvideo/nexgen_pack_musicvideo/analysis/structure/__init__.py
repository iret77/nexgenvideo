"""Structure-Detection: Section-Kandidaten aus mehreren Detectoren.

Jeder Detector implementiert das Protocol `StructureDetector`. Die Pipeline
ruft alle verfügbaren auf, der Consolidator mischt die Ergebnisse.
"""

from __future__ import annotations

from pathlib import Path
from typing import Protocol

from nexgen_pack_musicvideo.analysis_schema import Section, StructureCandidate


class StructureDetector(Protocol):
    """Liefert Section-Kandidaten aus einer Audio-Datei."""

    name: str

    def detect(self, audio_path: Path, duration_s: float) -> list[Section]:
        ...


def to_candidate(detector: StructureDetector, sections: list[Section], notes: str | None = None) -> StructureCandidate:
    return StructureCandidate(source=detector.name, sections=sections, notes=notes)  # type: ignore[arg-type]
