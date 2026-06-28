"""Aspect-Ratio-Mapping: Brief-Aspect (semantisch) zu Provider-Format.

WICHTIG: Aspect-Resolution geht ueber `resolve_brief_aspect(brief)` —
das ist die Single Source of Truth fuer alle Render-/Sheet-Pfade.
to_runway_ratio()/to_openai_ratio() sind nur die Mapping-Helper; sie
fallen auf 16:9 zurueck wenn der Aspect-String unbekannt ist (stiller
Fallback). Vor v0.10.8 hat das gefuehrt zu: brief.aspect_ratio=OTHER
mit aspect_ratio_other='3:4' wurde im Dispatcher zu '1280:720' (16:9),
weil 'other' nicht in der Map war. Resultat: jeder Render in 16:9,
unabhaengig vom Brief.


Brief.aspect_ratio liefert semantische Werte ("16:9", "9:16", "1:1",
"4:5"). Verschiedene Provider erwarten unterschiedliche Formate:

- Runway:  Pixel-Strings mit ":" (z.B. "1280:720", "720:1280")
- Google:  Aspect-Strings ("16:9", "9:16", ...)
- OpenAI:  Pixel-Strings mit "x" (z.B. "1024x1024", "1024x1536")

Dieses Modul ist die Single Source of Truth fuer die Mappings.
Fruehere Inline-Mappings in compatibility.py, sheet.py und dispatcher.py
sind v0.10.6 hier zusammengezogen.
"""

from __future__ import annotations


# Brief-Aspect-Strings -> Aspect als Float (fuer Vergleiche).
ASPECT_TO_FLOAT: dict[str, float] = {
    "16:9": 16 / 9,
    "9:16": 9 / 16,
    "1:1": 1.0,
    "4:5": 4 / 5,
    "5:4": 5 / 4,
    "4:3": 4 / 3,
    "3:4": 3 / 4,
    "21:9": 21 / 9,
    "9:21": 9 / 21,
}


# Brief-Aspect -> Runway-Pixel-String.
ASPECT_TO_RUNWAY_PIXEL: dict[str, str] = {
    "16:9": "1280:720",
    "9:16": "720:1280",
    "1:1": "960:960",
    "4:5": "832:1104",
    "5:4": "1104:832",
    "4:3": "960:720",
    "3:4": "720:960",
    "21:9": "2560:1080",
    "9:21": "1080:2560",
}


# Brief-Aspect -> OpenAI-Pixel-String (GPT-Image).
ASPECT_TO_OPENAI_PIXEL: dict[str, str] = {
    "16:9": "1536x1024",
    "9:16": "1024x1536",
    "1:1": "1024x1024",
    "4:3": "1536x1024",
    "3:4": "1024x1536",
}


def to_runway_ratio(aspect: str) -> str:
    """Aspect-String ('16:9') -> Runway-Pixel-String ('1280:720').

    Fallback: 1280:720 wenn unbekannt — Runway-Default. Niemals leeren
    String zurueckgeben, das Runway-SDK wuerde failen.
    """
    return ASPECT_TO_RUNWAY_PIXEL.get(aspect, "1280:720")


def to_openai_ratio(aspect: str) -> str:
    """Aspect-String -> OpenAI-Pixel-String."""
    return ASPECT_TO_OPENAI_PIXEL.get(aspect, "1024x1024")


def aspect_float(aspect: str) -> float | None:
    """Aspect-String -> Float (W/H). None wenn unbekannt."""
    return ASPECT_TO_FLOAT.get(aspect)


import re

_OTHER_ASPECT_RE = re.compile(r"\b(\d{1,4})\s*[:x/×]\s*(\d{1,4})\b")


def parse_aspect_freeform(text: str) -> str | None:
    """'3:4 (960x1280)' -> '3:4'. None wenn nichts brauchbares.

    Wir matchen den FUEHRENDEN W:H-Token. '960x1280' am Anfang waere
    auch ein Match, das ist OK — to_runway_ratio() kennt z.B. '960x720'
    nicht direkt, aber resolve_brief_aspect() reduziert es auf das
    semantische Verhaeltnis durch ggT.
    """
    if not text:
        return None
    m = _OTHER_ASPECT_RE.search(text)
    if m is None:
        return None
    w, h = int(m.group(1)), int(m.group(2))
    if w <= 0 or h <= 0:
        return None
    # Wenn die Zahlen Pixel sind (z.B. 960x1280), auf ggT reduzieren.
    from math import gcd
    g = gcd(w, h)
    return f"{w // g}:{h // g}"


class AspectUnresolvable(ValueError):
    """Brief.aspect_ratio=OTHER ohne parsebaren aspect_ratio_other."""


def resolve_brief_aspect(brief) -> str:
    """Brief -> semantischer Aspect-String ('3:4' etc.).

    Bei brief.aspect_ratio=OTHER wird `aspect_ratio_other` geparst.
    Wirft AspectUnresolvable, wenn weder Enum noch Freitext einen
    konkreten Aspect liefern — damit der Stille-16:9-Fallback nie
    wieder still durchlaeuft.
    """
    if brief is None:
        raise AspectUnresolvable("brief ist None")
    aspect_attr = getattr(brief, "aspect_ratio", None)
    if aspect_attr is None:
        raise AspectUnresolvable("brief hat kein aspect_ratio-Feld")
    val = aspect_attr.value if hasattr(aspect_attr, "value") else str(aspect_attr)
    if val and val != "other":
        return val
    # OTHER -> Freitext parsen
    freeform = getattr(brief, "aspect_ratio_other", None) or ""
    parsed = parse_aspect_freeform(freeform)
    if parsed is None:
        raise AspectUnresolvable(
            f"brief.aspect_ratio=other und aspect_ratio_other="
            f"{freeform!r} liefert kein W:H. Brief mit konkretem Aspect "
            "neu setzen oder Enum-Wert (z.B. '3:4') verwenden."
        )
    return parsed


_SUPPORTED_RATIO_RE = re.compile(r"^(\d+)\s*[:x×]\s*(\d+)$")


def _ratio_string_to_dims(s: str) -> tuple[int, int] | None:
    """'720:960' / '720x960' -> (720, 960). None bei unparsebar."""
    m = _SUPPORTED_RATIO_RE.match(s.strip())
    if m is None:
        return None
    return int(m.group(1)), int(m.group(2))


def _ratio_string_to_float(s: str) -> float | None:
    """'720:960' -> 0.75. None bei unparsebar oder 0."""
    dims = _ratio_string_to_dims(s)
    if dims is None:
        return None
    w, h = dims
    if h == 0:
        return None
    return w / h


def resolve_for_model(
    aspect: str,
    supported_ratios: tuple[str, ...],
    *,
    tolerance: float = 0.05,
) -> str | None:
    """Aspect-String semantisch gegen Modell-Caps aufloesen.

    Bug-Klasse claude_mouse: to_runway_ratio('3:4') liefert '720:960',
    aber seedance2.supported_ratios enthaelt das 3:4-Verhaeltnis als
    '960:1280' (gleicher Float 0.75, andere Pixelaufloesung). Reiner
    String-Match feuerte fuer beide RATIO_NOT_SUPPORTED.

    Diese Funktion:
    1. Parst den Aspect-String zu einem Float (semantisches Verhaeltnis).
    2. Parst alle supported_ratios zu Floats.
    3. Findet alle Matches innerhalb tolerance.
    4. Waehlt unter den Matches die hoechste Aufloesung (W*H).

    Returns None, wenn kein supported_ratio dem Aspect entspricht —
    dann ist es ein echter Cap-Mismatch (kein RATIO_NOT_SUPPORTED-
    Fehlalarm wie bei reinem String-Vergleich).
    """
    if not supported_ratios:
        return None
    target_float = aspect_float(aspect) or _ratio_string_to_float(aspect)
    if target_float is None:
        return None
    candidates: list[tuple[int, str]] = []
    for s in supported_ratios:
        dims = _ratio_string_to_dims(s)
        if dims is None:
            # Z.B. Google-Aspect-String '16:9' — Float-Vergleich via
            # ASPECT_TO_FLOAT.
            f = ASPECT_TO_FLOAT.get(s) or _ratio_string_to_float(s)
            if f is None:
                continue
            if abs(f - target_float) <= tolerance:
                candidates.append((1, s))  # keine Pixel-Info, niedrige Prio
            continue
        w, h = dims
        if h == 0:
            continue
        f = w / h
        if abs(f - target_float) <= tolerance:
            candidates.append((w * h, s))
    if not candidates:
        return None
    # Hoechste Aufloesung gewinnt.
    candidates.sort(key=lambda t: t[0], reverse=True)
    return candidates[0][1]


def resolve_for_provider(aspect: str, supported_ratios: tuple[str, ...]) -> str:
    """Brief-Aspect zu provider-kompatiblem String aufloesen.

    Wrapper um `resolve_for_model()`. Wenn nichts matched, Fallback auf
    `supported_ratios[0]` (gewollt: bei Aspect-Mismatch lieber im
    naechstbesten Format rendern als crashen — fuer Sheet-Generation OK,
    fuer den Video-Render aber NICHT, dort lieber Dispatcher
    `RuntimeError` werfen).
    """
    if not supported_ratios:
        return aspect
    matched = resolve_for_model(aspect, supported_ratios)
    if matched is not None:
        return matched
    # Echter Mismatch — Erstes nehmen mit Aspect-Verzerrung. Aufrufer
    # sollte das aktiv pruefen, nicht stillschweigend akzeptieren.
    return supported_ratios[0]
