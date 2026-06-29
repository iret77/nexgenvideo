"""Director-Pattern-Schema (v0.12.0).

User-Spec: Shot-/Cut-/Tempo-Planung soll sich an bekannten Vorlagen
(Filme, Musikvideos, Regisseure, DOPs) orientieren, soweit sie zum
Projekttyp passen. Pattern werden im Brief vorgeschlagen, im
Storyboard als Compose-Backbone genutzt, in der Sanity-Phase via
PATTERN_DRIFT-Check gegen die reale Planung gespiegelt.

WICHTIG zur Empirie:
- Jeder Pattern-Eintrag MUSS `references[].sources[]` mit pruefbaren
  URLs liefern. Keine erfundenen Daten ohne Quelle.
- Pattern-Werte (asl_range, framing_mix) sind als
  "approximation_basis" markiert — Skill arbeitet auf Heuristik-
  Niveau, nicht auf Cinemetrics-Praezision. Wer harte Stats braucht,
  pflegt die Pattern nach.
- Pattern beschreibt eine SPRACHE, keine ZWANGSJACKE — Escape via
  `pattern_override:` in Brief oder Shot.notes.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Annotated

import yaml
from pydantic import BaseModel, ConfigDict, Field

from nexgen_engine.brief.schema import (
    AspectRatio, ConceptType, FigurePresence, VisualMedium,
)
from nexgen_engine.shotlist.schema import Framing


class MoodBand(str, Enum):
    """Grob-Klassifikation der Mood — fuer Pattern-Trigger."""
    INTROSPECTIVE = "introspective"
    MELANCHOLIC = "melancholic"
    EUPHORIC = "euphoric"
    HIGH_ENERGY = "high_energy"
    AGGRESSIVE = "aggressive"
    DREAMY = "dreamy"
    INTIMATE = "intimate"
    NARRATIVE = "narrative"
    CINEMATIC = "cinematic"


class TempoBand(str, Enum):
    """Grob-BPM-Banden (analog zur Tempo-Klassifikation des Packs)."""
    SLOW = "slow"          # < 80 BPM
    MEDIUM = "medium"      # 80-110 BPM
    UPTEMPO = "uptempo"    # 110-140 BPM
    FAST = "fast"          # > 140 BPM


def _tempo_band(perceived_bpm: float) -> TempoBand:
    if perceived_bpm < 80:
        return TempoBand.SLOW
    if perceived_bpm < 110:
        return TempoBand.MEDIUM
    if perceived_bpm < 140:
        return TempoBand.UPTEMPO
    return TempoBand.FAST


class ReferenceSource(BaseModel):
    """Pruefbare Quelle fuer eine Pattern-Referenz."""
    model_config = ConfigDict(extra="forbid")
    label: str
    """Kurzbeschreibung der Quelle, z.B. 'Wikipedia: Hype Williams videography'."""
    url: str
    """Voller URL, https-bevorzugt."""


class PatternReference(BaseModel):
    """Eine konkrete Vorlage — Director / Film / Musikvideo / DOP."""
    model_config = ConfigDict(extra="forbid")
    name: str
    """Name des Referenz-Artefakts/Personen, z.B. 'Anton Corbijn —
    Depeche Mode, Joy Division videography'."""
    role: str
    """Rolle: 'director', 'dop', 'editor', 'film', 'music_video'."""
    notable_works: list[str] = Field(default_factory=list)
    """Beispielwerke, kurze Liste — nicht erschoepfend."""
    sources: list[ReferenceSource]
    """Mindestens eine Quelle, sonst ist die Referenz Phantasie."""


class SectionArcStep(BaseModel):
    """Ein Schritt im idealen Section-Bogen (Intro/Verse/Chorus/Bridge)."""
    model_config = ConfigDict(extra="forbid")
    role: str
    """Funktionsname: 'establishing', 'reveal', 'detail', 'cutaway',
    'performance', 'reaction', 'transition', 'resolve'."""
    framing_hint: list[Framing]
    """Welche Framings tragen diese Funktion typisch."""
    notes: str = ""
    """Optionaler Kommentar zur Rolle in diesem Pattern."""


class PatternTriggers(BaseModel):
    """Welche Brief-Eigenschaften aktivieren dieses Pattern."""
    model_config = ConfigDict(extra="forbid")
    visual_mediums: list[VisualMedium] = Field(default_factory=list)
    """Leer = alle Mediums passen."""
    moods: list[MoodBand] = Field(default_factory=list)
    """Leer = alle Moods passen."""
    tempo_bands: list[TempoBand] = Field(default_factory=list)
    """Leer = alle Tempi passen."""
    concept_types: list[ConceptType] = Field(default_factory=list)
    figures: list[FigurePresence] = Field(default_factory=list)
    aspect_ratios: list[AspectRatio] = Field(default_factory=list)


class FramingMix(BaseModel):
    """Soll-Verteilung der Framings, in Prozent (Summe ~100)."""
    model_config = ConfigDict(extra="forbid")
    wide_pct: Annotated[int, Field(ge=0, le=100)] = 0
    full_pct: Annotated[int, Field(ge=0, le=100)] = 0
    ms_pct: Annotated[int, Field(ge=0, le=100)] = 0
    mcu_pct: Annotated[int, Field(ge=0, le=100)] = 0
    cu_pct: Annotated[int, Field(ge=0, le=100)] = 0
    ecu_pct: Annotated[int, Field(ge=0, le=100)] = 0
    ots_pct: Annotated[int, Field(ge=0, le=100)] = 0
    pov_pct: Annotated[int, Field(ge=0, le=100)] = 0
    insert_pct: Annotated[int, Field(ge=0, le=100)] = 0
    aerial_pct: Annotated[int, Field(ge=0, le=100)] = 0

    def by_framing(self) -> dict[Framing, int]:
        return {
            Framing.WIDE: self.wide_pct,
            Framing.FULL: self.full_pct,
            Framing.MS: self.ms_pct,
            Framing.MCU: self.mcu_pct,
            Framing.CU: self.cu_pct,
            Framing.ECU: self.ecu_pct,
            Framing.OTS: self.ots_pct,
            Framing.POV: self.pov_pct,
            Framing.INSERT: self.insert_pct,
            Framing.AERIAL: self.aerial_pct,
        }


class AslRange(BaseModel):
    """Average Shot Length: Bereich in Sekunden."""
    model_config = ConfigDict(extra="forbid")
    min_s: Annotated[float, Field(gt=0)]
    max_s: Annotated[float, Field(gt=0)]
    typical_s: Annotated[float, Field(gt=0)]


class Pattern(BaseModel):
    """Director-Pattern: positives Compose-Backbone fuer Shotlist."""
    model_config = ConfigDict(extra="forbid")
    id: str
    """Slug-ID, z.B. 'narrative-folk-static-long-takes'."""
    name: str
    """Lesbarer Name fuer den User, z.B. 'Narrative Folk — static long takes'."""
    description: str
    """1-3 Saetze, was diesen Pattern auszeichnet (fuer User-Anzeige)."""
    triggers: PatternTriggers
    references: list[PatternReference]
    """Pruefbare Vorlagen mit Quellen — mindestens eine."""
    section_arc: list[SectionArcStep]
    """Empfohlene Innen-Struktur einer Section."""
    framing_mix: FramingMix
    """Soll-Verteilung der Framings ueber die ganze Shotlist."""
    asl_range: AslRange
    camera_vocabulary: list[str]
    """Bevorzugte Bewegungs-Sprache, z.B. ['static hold', 'slow push-in',
    'lateral track']."""
    lighting_signature: str
    """Lighting-Stil-Kurzfassung, z.B. 'warm natural daylight, soft
    shadows, golden-hour bias'."""
    approximation_basis: str
    """Quellen-Disziplin: woher kommen die framing_mix / asl_range -
    Werte? z.B. 'qualitative aggregation from cited videography pages,
    not Cinemetrics-grade; refine via real shot counts.'."""

    def matches(
        self,
        *,
        visual_medium: VisualMedium | None,
        mood: MoodBand | None,
        tempo: TempoBand | None,
        concept: ConceptType | None,
        figures: FigurePresence | None,
        aspect: AspectRatio | None,
    ) -> bool:
        """True wenn alle gesetzten Trigger-Listen den Input zulassen
        (leere Liste = wildcard).

        Backward-Kompat-Eingang fuer v0.12.x-Aufrufer. Neue Aufrufer
        nutzen `score_against()` und sortieren nach Score.
        """
        t = self.triggers
        if t.visual_mediums and visual_medium is not None and visual_medium not in t.visual_mediums:
            return False
        if t.moods and mood is not None and mood not in t.moods:
            return False
        if t.tempo_bands and tempo is not None and tempo not in t.tempo_bands:
            return False
        if t.concept_types and concept is not None and concept not in t.concept_types:
            return False
        if t.figures and figures is not None and figures not in t.figures:
            return False
        if t.aspect_ratios and aspect is not None and aspect not in t.aspect_ratios:
            return False
        return True

    def score_against(
        self,
        *,
        visual_medium: VisualMedium | None,
        mood: MoodBand | None,
        tempo: TempoBand | None,
        concept: ConceptType | None,
        figures: FigurePresence | None,
        aspect: AspectRatio | None,
        allow_genre_cross: bool = False,
    ) -> "PatternScore":
        """Gewichteter Match-Score gegen User-Brief-Eingaben (v0.13.0).

        Punkte-System:
        - visual_medium: +3 wenn match. Mismatch: -10 (hartes Veto)
          ODER -2 wenn `allow_genre_cross=True` (Codex F7,
          `brief.allow_genre_cross_patterns`). Hartes Veto verhindert
          standardmaessig dass z.B. ein Anime-Pattern auf Live-Action-
          Brief vorgeschlagen wird — bewusster Genre-Cross hebt das auf.
        - mood: +2 wenn match, -2 wenn Mismatch.
        - tempo: +2 wenn match, -1 wenn Mismatch.
        - concept: +2 wenn match, -1 wenn Mismatch.
        - figures: +1 wenn match, -1 wenn Mismatch.
        - aspect: +1 wenn match, 0 wenn Mismatch (sehr selten gefiltert).
        - Wildcard (leere Trigger-Liste): 0 Punkte (neutral).
        - Input None: 0 Punkte (User-Brief hat das Feld nicht gesetzt).

        Resultat ist ein `PatternScore` mit Score-Total und einer
        strukturierten `reasons`-Liste — letzteres ist die Begruendung,
        die der Brief-Agent dem User anzeigt.
        """
        vm_mismatch = -2 if allow_genre_cross else -10
        t = self.triggers
        score = 0
        reasons: list[PatternMatchReason] = []

        def _check(
            field: str,
            input_val,
            allowed_list,
            match_pt: int,
            mismatch_pt: int,
        ) -> None:
            nonlocal score
            if input_val is None:
                return
            if not allowed_list:
                # Wildcard — Pattern stellt keine Anforderung an dieses Feld.
                return
            input_label = (
                input_val.value if hasattr(input_val, "value") else str(input_val)
            )
            if input_val in allowed_list:
                score += match_pt
                reasons.append(PatternMatchReason(
                    field=field, hit=True, points=match_pt,
                    input_value=input_label,
                ))
            else:
                score += mismatch_pt
                reasons.append(PatternMatchReason(
                    field=field, hit=False, points=mismatch_pt,
                    input_value=input_label,
                ))

        _check("visual_medium", visual_medium, t.visual_mediums, 3, vm_mismatch)
        _check("mood", mood, t.moods, 2, -2)
        _check("tempo", tempo, t.tempo_bands, 2, -1)
        _check("concept", concept, t.concept_types, 2, -1)
        _check("figures", figures, t.figures, 1, -1)
        _check("aspect", aspect, t.aspect_ratios, 1, 0)

        return PatternScore(
            pattern_id=self.id,
            pattern_name=self.name,
            score=score,
            reasons=reasons,
        )


@dataclass(frozen=True)
class PatternMatchReason:
    """Ein einzelnes Trigger-Match im Pattern-Scoring (v0.13.0)."""
    field: str        # "visual_medium" | "mood" | "tempo" | "concept" | "figures" | "aspect"
    hit: bool         # True = Trigger matched, False = Mismatch
    points: int       # Punktebeitrag (positiv oder negativ)
    input_value: str  # User-Eingabe zur Anzeige


@dataclass(frozen=True)
class PatternScore:
    """Ergebnis eines Pattern-Scoring-Laufs (v0.13.0)."""
    pattern_id: str
    pattern_name: str
    score: int
    reasons: list[PatternMatchReason]

    def hit_summary(self) -> str:
        """Begruendung als Klartext fuer User-Anzeige.

        Beispiel: 'visual_medium ✓ · mood ✓ · tempo ✓ · concept ✓
        (Score 9)'.
        """
        if not self.reasons:
            return f"(keine Trigger geprueft, Score {self.score})"
        parts = [
            f"{r.field} {'✓' if r.hit else '✗'}"
            for r in self.reasons
        ]
        return f"{' · '.join(parts)} (Score {self.score})"


# ----- Loader ----------------------------------------------------------------

def patterns_dir() -> Path:
    return Path(__file__).parent / "library"


def load_pattern(yaml_path: Path) -> Pattern:
    data = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    return Pattern.model_validate(data)


def load_all_patterns() -> list[Pattern]:
    out: list[Pattern] = []
    pdir = patterns_dir()
    if not pdir.is_dir():
        return out
    for yaml_file in sorted(pdir.glob("*.yaml")):
        out.append(load_pattern(yaml_file))
    return out


def score_patterns(
    *,
    visual_medium: VisualMedium | None = None,
    mood: MoodBand | None = None,
    perceived_bpm: float | None = None,
    concept: ConceptType | None = None,
    figures: FigurePresence | None = None,
    aspect: AspectRatio | None = None,
    max_results: int = 5,
    min_score: int | None = 0,
    allow_genre_cross: bool = False,
) -> list[tuple[Pattern, PatternScore]]:
    """Liefert die Pattern-Library sortiert nach Match-Score (v0.13.0).

    Args:
        visual_medium..aspect: User-Brief-Eingaben (None = nicht gesetzt).
        max_results: Top-N nach Score.
        min_score: Pattern unterhalb dieser Schwelle werden ausgefiltert.
            None = keine Schwelle (auch negative Scores erlaubt).
        allow_genre_cross: True hebt das visual_medium-Veto auf
            (-10 → -2). Aus `brief.allow_genre_cross_patterns`
            durchreichen wenn Caller das Flag im Brief hat.

    Returns:
        Liste von `(Pattern, PatternScore)`-Tupeln, absteigend nach
        score. Brief-Agent zeigt die Top-N mit `score.hit_summary()`
        als Begruendung.
    """
    tempo_band = _tempo_band(perceived_bpm) if perceived_bpm is not None else None
    scored: list[tuple[Pattern, PatternScore]] = []
    for p in load_all_patterns():
        s = p.score_against(
            visual_medium=visual_medium,
            mood=mood,
            tempo=tempo_band,
            concept=concept,
            figures=figures,
            aspect=aspect,
            allow_genre_cross=allow_genre_cross,
        )
        if min_score is not None and s.score < min_score:
            continue
        scored.append((p, s))
    scored.sort(key=lambda ps: ps[1].score, reverse=True)
    return scored[:max_results]


def suggest_patterns(
    *,
    visual_medium: VisualMedium | None = None,
    mood: MoodBand | None = None,
    perceived_bpm: float | None = None,
    concept: ConceptType | None = None,
    figures: FigurePresence | None = None,
    aspect: AspectRatio | None = None,
    max_results: int = 3,
) -> list[Pattern]:
    """Filter ueber alle bekannten Pattern (v0.12.x Backward-Kompat).

    Hard-Filter via `matches()`. Neue Aufrufer sollten
    `score_patterns()` nutzen — das liefert eine sortierte Liste mit
    PatternScore-Begruendung.
    """
    tempo_band = _tempo_band(perceived_bpm) if perceived_bpm is not None else None
    matches = [
        p for p in load_all_patterns()
        if p.matches(
            visual_medium=visual_medium,
            mood=mood,
            tempo=tempo_band,
            concept=concept,
            figures=figures,
            aspect=aspect,
        )
    ]
    return matches[:max_results]


__all__ = [
    "AslRange",
    "FramingMix",
    "MoodBand",
    "Pattern",
    "PatternMatchReason",
    "PatternReference",
    "PatternScore",
    "PatternTriggers",
    "ReferenceSource",
    "SectionArcStep",
    "TempoBand",
    "_tempo_band",
    "load_all_patterns",
    "load_pattern",
    "patterns_dir",
    "score_patterns",
    "suggest_patterns",
]
