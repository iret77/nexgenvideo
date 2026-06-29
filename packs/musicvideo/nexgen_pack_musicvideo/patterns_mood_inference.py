"""Mood-Inferenz fuer Pattern-Vorschlaege (v0.13.0).

User-Direktive: "Aus beidem mit Brief-Prioritaet". Heisst:

1. **Primary** — `brief.tone` (ToneTag-Liste) als Quelle. Die Enums
   werden auf MoodBand abgebildet.
2. **Override / Verfeinerung** — Treatment-Markdown-Heuristik
   (Stoppwort-Listen) fuer Faelle, wo der Brief vage ist oder
   der Treatment-Text einen anderen Ton andeutet.

Keine NLP-Modelle, keine Halluzinations-Quelle — pure Lexikon-
Heuristik mit klaren Schwellen.
"""

from __future__ import annotations

import re
from collections import Counter
from pathlib import Path

from nexgen_engine.brief.schema import Brief, ToneTag
from nexgen_pack_musicvideo.patterns_schema import MoodBand


# ----- ToneTag → MoodBand-Mapping --------------------------------------------
#
# Brief.tone_tags ist die kanonische User-Antwort. Die Enums haben
# semantische Ueberlappung; ein ToneTag kann mehrere MoodBands
# implizieren (z.B. "dark" → aggressive ODER melancholic). Wir nehmen
# pro ToneTag den DOMINANTEN MoodBand-Kandidaten.

_TONE_TO_MOOD: dict[ToneTag, MoodBand] = {
    ToneTag.MELANCHOLIC: MoodBand.MELANCHOLIC,
    ToneTag.IRONIC: MoodBand.NARRATIVE,         # ironic ≈ narrative-distance
    ToneTag.EUPHORIC: MoodBand.EUPHORIC,
    ToneTag.DARK: MoodBand.AGGRESSIVE,
    ToneTag.SURREAL: MoodBand.DREAMY,
    ToneTag.POETIC: MoodBand.INTROSPECTIVE,
    ToneTag.ENERGETIC: MoodBand.HIGH_ENERGY,
    ToneTag.QUIET: MoodBand.INTIMATE,
    # ToneTag.OTHER fallend ohne Mapping
}


def mood_from_tone_tags(tones: list[ToneTag] | None) -> MoodBand | None:
    """Primaere Mood-Inferenz aus Brief.tone_tags (v0.13.0).

    Mehrfach-Tones: das erste gemappte gewinnt — der User hat die
    Reihenfolge bewusst gesetzt.
    Leer / None / nur OTHER: None — Caller faellt auf Treatment-
    Heuristik zurueck.
    """
    if not tones:
        return None
    for t in tones:
        mapped = _TONE_TO_MOOD.get(t)
        if mapped is not None:
            return mapped
    return None


# ----- Treatment-Markdown-Heuristik ------------------------------------------
#
# Stoppwort-Listen pro MoodBand. Wenn der Treatment-Text mehr Treffer
# fuer Mood A als fuer Mood B enthaelt, ist A der dominante Ton.
# Schwelle: mindestens 2 Treffer fuer eine MoodBand, sonst None.

_MOOD_KEYWORDS: dict[MoodBand, tuple[str, ...]] = {
    MoodBand.INTROSPECTIVE: (
        # English
        "reflect", "introspect", "thought", "memory", "remember",
        "inner", "alone", "solitude", "quiet contemplation",
        # German
        "nachdenk", "erinnerung", "innen", "stille", "alleine",
        "still", "ruhig",
    ),
    MoodBand.MELANCHOLIC: (
        "melanchol", "sad", "longing", "yearn", "wistful", "bittersweet",
        "lonely", "tear", "heartache", "grief",
        "trauer", "wehmut", "sehnsucht", "einsam",
    ),
    MoodBand.EUPHORIC: (
        "euphoric", "joy", "joyful", "celebration", "celebrate",
        "exhilarat", "ecstatic", "uplift", "triumphant",
        "freude", "feier", "rausch", "ekstatisch",
    ),
    MoodBand.HIGH_ENERGY: (
        "energetic", "energy", "kinetic", "explosive", "frantic", "pulse",
        "drive", "speed", "rush", "movement",
        "energie", "rasant", "treibend", "schnell",
    ),
    MoodBand.AGGRESSIVE: (
        "aggressive", "anger", "rage", "fierce", "violent", "dark",
        "brutal", "intense", "ominous", "menacing",
        "aggressiv", "wut", "duester", "dunkel", "brutal",
    ),
    MoodBand.DREAMY: (
        "dream", "dreamy", "ethereal", "surreal", "hazy", "floating",
        "otherworldly", "mysterious", "fog", "mist",
        "traum", "traeumerisch", "schwebend", "nebel", "surreal",
    ),
    MoodBand.INTIMATE: (
        "intimate", "tender", "soft", "vulnerable", "whisper", "close",
        "bedroom", "quiet moment",
        "intim", "zart", "verletzlich", "fluester", "nah",
    ),
    MoodBand.NARRATIVE: (
        "story", "narrative", "character arc", "plot", "scene", "act",
        "chapter", "tale",
        "geschichte", "erzaehl", "kapitel", "figur",
    ),
    MoodBand.CINEMATIC: (
        "cinematic", "epic", "grand", "sweeping", "panoramic",
        "filmic", "cinema",
        "filmisch", "episch", "kinoreif", "monumental",
    ),
}


def _treatment_path(project_dir: Path) -> Path | None:
    """Findet die aktuellste treatment/vN.md oder treatment/current.md."""
    t_dir = project_dir / "treatment"
    if not t_dir.is_dir():
        return None
    current = t_dir / "current.md"
    if current.exists():
        return current
    candidates = sorted(
        t_dir.glob("v*.md"),
        key=lambda p: int(re.match(r"v(\d+)", p.stem).group(1)),
        reverse=True,
    ) if list(t_dir.glob("v*.md")) else []
    return candidates[0] if candidates else None


def mood_from_treatment(text: str) -> MoodBand | None:
    """Heuristik-Inferenz aus Treatment-Markdown-Text.

    Zaehlt Stoppwort-Treffer pro MoodBand. Gewinner braucht
    mindestens 2 Treffer UND mindestens 1 mehr als der Zweitplatzierte
    (sonst zu uneindeutig). None bei flachem Verhaeltnis.
    """
    if not text or not text.strip():
        return None
    lower = text.lower()
    counts: Counter[MoodBand] = Counter()
    for mood, keywords in _MOOD_KEYWORDS.items():
        for kw in keywords:
            # \b-Match, case-insensitive
            hits = len(re.findall(rf"\b{re.escape(kw)}", lower))
            counts[mood] += hits
    if not counts:
        return None
    top = counts.most_common(2)
    if not top or top[0][1] < 2:
        return None
    if len(top) > 1 and top[0][1] == top[1][1]:
        return None  # Tie — zu uneindeutig
    return top[0][0]


def infer_mood(
    brief: Brief | None,
    project_dir: Path | None = None,
) -> tuple[MoodBand | None, str]:
    """Hybrid-Inferenz Brief-Priority + Treatment-Override (v0.13.0).

    Returns (MoodBand | None, source_label).
    source_label fuer User-Anzeige: "brief.tone", "treatment",
    "fallback (kein Match)".
    """
    if brief is not None:
        m = mood_from_tone_tags(brief.tone)  # Brief-Feld heisst tone, nicht tone_tags
        if m is not None:
            return m, "brief.tone"
    # Treatment-Fallback nur wenn project_dir mitgegeben.
    if project_dir is not None:
        tpath = _treatment_path(project_dir)
        if tpath is not None and tpath.exists():
            text = tpath.read_text(encoding="utf-8")
            m = mood_from_treatment(text)
            if m is not None:
                return m, "treatment"
    return None, "fallback (kein Match)"
