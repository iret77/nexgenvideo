"""Analysis-Schema v2 (abwärtskompatibel zu v1).

v2 führt folgende Felder ein, alle optional (fehlen in v1-Analysen):
- stems_path: Pfad zu vocals-/drums-/...-Stems (demucs)
- alignment: Word/Line-Level Forced-Alignment gegen bereitgestellte Lyrics
- structure_sources: Mehrere Section-Kandidaten aus verschiedenen Detectoren
- energy_curve, tempo_curve, key, chord_progression

Die primäre `sections`-Liste wird vom Consolidator zusammengeführt.
"""

from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

ANALYSIS_SCHEMA_VERSION = "analysis/v2"


class Section(BaseModel):
    model_config = ConfigDict(extra="forbid")

    index: int
    start: float
    end: float
    cluster: int
    label: str | None = None  # narrativ, gesetzt durch analysis-agent
    source: str | None = None  # "alignment" | "essentia" | "librosa" | "consolidated"
    confidence: float | None = None


class AlignmentLine(BaseModel):
    model_config = ConfigDict(extra="forbid")

    start: float
    end: float
    text: str
    section_marker: str | None = None  # z.B. "verse1", "chorus1" — aus [Section]-Markern
    words: list[dict] = Field(default_factory=list)  # [{text, start, end, score}]


class StructureCandidate(BaseModel):
    """Ein Section-Kandidatensatz aus einem bestimmten Detector."""

    model_config = ConfigDict(extra="forbid")

    source: Literal["alignment", "essentia", "librosa"]
    sections: list[Section] = Field(default_factory=list)
    notes: str | None = None


class EnergyPoint(BaseModel):
    model_config = ConfigDict(extra="forbid")

    t: float  # Sekunden
    rms: float  # normiert 0..1


class TempoPoint(BaseModel):
    model_config = ConfigDict(extra="forbid")

    t: float
    bpm: float


class Stems(BaseModel):
    model_config = ConfigDict(extra="forbid")

    vocals: str | None = None  # relativ zum Projektordner
    drums: str | None = None
    bass: str | None = None
    other: str | None = None


class Chord(BaseModel):
    model_config = ConfigDict(extra="forbid")

    start: float
    end: float
    label: str  # z.B. "Am", "G7", "C:maj"


class Interpretation(BaseModel):
    model_config = ConfigDict(extra="allow")

    section_labels: list[dict] = Field(default_factory=list)
    anomalies: list[dict] = Field(default_factory=list)
    overall_character: str = ""


class Analysis(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_: str = Field(alias="schema", default=ANALYSIS_SCHEMA_VERSION)
    project: str
    song_path: str
    sample_rate: int
    duration_s: Annotated[float, Field(gt=0)]

    # Rhythm
    bpm: Annotated[float, Field(gt=0)]
    """Technische BPM-Messung (essentia / madmom / librosa)."""

    tempo_multiplier: float = 1.0
    """User-/A2-bestätigter Multiplier für das **wahrgenommene** Tempo.
    Typische Werte: 0.5 (Track wirkt halb so schnell wie gemessen) / 1.0
    (passt) / 2.0 (Track wirkt doppelt so schnell). Wird in der A2-Phase
    interaktiv festgelegt, weil der technische Wert oft die Hälfte/das
    Doppelte des subjektiven Tempos ist und das strukturell aufs
    Storyboard/Shotlist-Pacing wirkt.

    Konsumenten (Sanity-Tempo-Cap, Storyboard-/Shotlist-Agent) sollen
    `perceived_bpm` nutzen, nicht den rohen `bpm`-Wert.
    """

    beats: list[float]
    downbeats: list[float]
    downbeat_source: Literal["madmom", "librosa-heuristic"]

    @property
    def perceived_bpm(self) -> float:
        """Subjektiv wahrgenommenes Tempo = bpm × tempo_multiplier.
        Default-Multiplier 1.0 → perceived_bpm == bpm."""
        return self.bpm * self.tempo_multiplier

    # Structure (konsolidiert)
    sections: list[Section]

    # v2 extensions (alle optional, können fehlen)
    stems: Stems | None = None
    alignment: list[AlignmentLine] = Field(default_factory=list)
    structure_candidates: list[StructureCandidate] = Field(default_factory=list)
    energy_curve: list[EnergyPoint] = Field(default_factory=list)
    tempo_curve: list[TempoPoint] = Field(default_factory=list)
    key: str | None = None  # "C major" / "A minor"
    chord_progression: list[Chord] = Field(default_factory=list)

    # Interpretation (gesetzt durch analysis-agent)
    interpretation: Interpretation | None = None

    # Welche Optional-Bausteine der Pipeline gelaufen sind
    pipeline_stages: list[str] = Field(default_factory=list)
