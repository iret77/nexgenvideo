"""Pattern-Aehnlichkeits-Matrix (v0.13.0).

User-Anfrage "aehnlich zu Shinkai aber mit mehr Aktion": der Skill
liefert die naechsten 3-5 Nachbarn eines Pattern.

Aehnlichkeit = gewichteter Mittelwert aus:
- Cosine-Similarity der framing_mix-Vektoren (Gewicht 0.5)
- Jaccard-Similarity der camera_vocabulary-Sets (Gewicht 0.3)
- Abstand der asl_range.typical_s (Gewicht 0.2, normalisiert auf
  log-Skala, weil ASL exponentiell variiert)

Keine ML, kein Training — pure Vektor-Mathe ueber strukturierte
Pattern-Felder.
"""

from __future__ import annotations

import math
import re

from nexgen_pack_musicvideo.patterns_schema import Pattern, load_all_patterns
from nexgen_engine.shotlist.schema import Framing


_FRAMINGS_ORDER = (
    Framing.WIDE, Framing.FULL, Framing.MS, Framing.MCU, Framing.CU,
    Framing.ECU, Framing.OTS, Framing.POV, Framing.INSERT, Framing.AERIAL,
)


def _framing_vector(p: Pattern) -> list[float]:
    mix = p.framing_mix.by_framing()
    return [float(mix[f]) for f in _FRAMINGS_ORDER]


def _cosine(a: list[float], b: list[float]) -> float:
    if len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


_WORD_RE = re.compile(r"[a-zA-Z]+")


def _camera_token_set(p: Pattern) -> set[str]:
    """Token-Set aus camera_vocabulary, fuer Jaccard."""
    tokens: set[str] = set()
    for entry in p.camera_vocabulary:
        for w in _WORD_RE.findall(entry.lower()):
            if len(w) >= 3:
                tokens.add(w)
    return tokens


def _jaccard(a: set[str], b: set[str]) -> float:
    if not a and not b:
        return 0.0
    return len(a & b) / max(len(a | b), 1)


def _asl_log_distance(a: float, b: float) -> float:
    """Distanz auf log-Skala, normalisiert auf [0, 1]. Naeher = besser."""
    if a <= 0 or b <= 0:
        return 0.0
    diff = abs(math.log10(a) - math.log10(b))
    # log10-Differenz von 1 = Faktor 10 = sehr entfernt.
    return max(0.0, 1.0 - min(1.0, diff))


def similarity(a: Pattern, b: Pattern) -> float:
    """Gewichteter Aehnlichkeits-Score zwischen zwei Pattern in [0, 1]."""
    cos = _cosine(_framing_vector(a), _framing_vector(b))
    jac = _jaccard(_camera_token_set(a), _camera_token_set(b))
    asl = _asl_log_distance(a.asl_range.typical_s, b.asl_range.typical_s)
    return 0.5 * cos + 0.3 * jac + 0.2 * asl


def suggest_similar(
    pattern_id: str, *, top: int = 5
) -> list[tuple[Pattern, float]]:
    """Liefert die Top-N aehnlichsten Pattern zu einem Anker-Pattern.

    User-Anfrage "aehnlich zu Shinkai" → Skill nutzt diese Funktion
    und zeigt 3-5 Nachbarn mit Score-Anzeige.
    """
    library = load_all_patterns()
    anchor = next((p for p in library if p.id == pattern_id), None)
    if anchor is None:
        return []
    scored: list[tuple[Pattern, float]] = []
    for p in library:
        if p.id == anchor.id:
            continue
        s = similarity(anchor, p)
        scored.append((p, s))
    scored.sort(key=lambda ps: ps[1], reverse=True)
    return scored[:top]
