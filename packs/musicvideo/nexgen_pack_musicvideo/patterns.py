"""Director-Pattern-Bibliothek (v0.12.0).

Pattern werden im Brief vorgeschlagen, im Storyboard als Compose-
Backbone genutzt und in der Sanity-Phase via PATTERN_DRIFT-Check
gegen die reale Planung gespiegelt.

Public API: `suggest_patterns(...)`, `load_pattern(path)`,
`load_all_patterns()`, plus die Schema-Klassen aus
`nexgen_pack_musicvideo.patterns_schema`.
"""

from nexgen_pack_musicvideo.patterns_mood_inference import (
    infer_mood,
    mood_from_tone_tags,
    mood_from_treatment,
)
from nexgen_pack_musicvideo.patterns_schema import (
    AslRange,
    FramingMix,
    MoodBand,
    Pattern,
    PatternMatchReason,
    PatternReference,
    PatternScore,
    PatternTriggers,
    ReferenceSource,
    SectionArcStep,
    TempoBand,
    load_all_patterns,
    load_pattern,
    patterns_dir,
    score_patterns,
    suggest_patterns,
)
from nexgen_pack_musicvideo.patterns_similarity import similarity, suggest_similar

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
    "infer_mood",
    "load_all_patterns",
    "load_pattern",
    "mood_from_tone_tags",
    "mood_from_treatment",
    "patterns_dir",
    "score_patterns",
    "similarity",
    "suggest_patterns",
    "suggest_similar",
]
