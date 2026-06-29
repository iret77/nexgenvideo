"""Pre-Call-Linter fuer gebaute provider_prompts.

Schliesst die Luecke zwischen Sanity (prueft `shot.visual_prompt` —
die Quelle) und Frame-Audit (prueft das gerenderte Bild — den Output).
Ein bekannter Fehlerfall demonstriert das: Sanity war gruen, der
Frame-Audit haette den 3D-Triptychon erkannt — aber erst nach dem
Provider-Call. Geld weg, Zeit weg.

Der Linter prueft den von `build_image_prompt` produzierten String,
**bevor** er an Gemini/OpenAI/Imagen geht. Erkennt Builder-Ausgaben,
die empirisch zu schlechten Outputs fuehren:

- Doppelter `Style:`-Tag (Style-Drift)
- Fehlende Anti-Triptychon-Direktive bei Multi-Ref
- Slop / Meta-Instruktionen / Numerierungs-Labels, die der Strip
  uebersehen hat
- Technisches Lingo (mm/fps/ISO), das durchgerutscht ist
- Lighting-Marker im finalen Prompt fehlt
- Ref-Hint-Count mismatch (Hint-Reihenfolge vs. uebergebene Refs)
- Leerer / zu kurzer Prompt
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

Severity = Literal["error", "warn", "info"]


@dataclass(frozen=True)
class LintFinding:
    severity: Severity
    code: str
    message: str


# Marker-Set fuer "Lighting im finalen Prompt vorhanden". Konsistent mit
# dem Seedance-Camera-Check — beide Listen muessen synchron bleiben.
_LIGHT_MARKERS = (
    # English
    "light", "lit", "lighting", "sunlight", "moonlight", "lamp",
    "backlit", "rim light", "rim-light", "shadow", "silhouette",
    "golden hour", "blue hour", "neon", "fluorescent", "overcast",
    "candle", "spot", "key light", "ambient", "diffuse", "harsh",
    "soft", "hard light", "natural light", "volumetric",
    "practical light", "tungsten", "daylight", "dusk", "dawn", "twilight",
    # German
    "licht", "beleucht", "schatten", "sonnenlicht", "mondlicht",
    "mittagslicht", "gegenlicht", "kerzenlicht", "lampenlicht",
    "sonnenaufgang", "sonnenuntergang", "daemmer", "dämmer",
    "morgenlicht", "abendlicht", "goldene stunde", "blaue stunde",
    "weich", "hart", "diffus",
)

# Slop, das im finalen Prompt nicht mehr auftauchen darf (Apiyi-Liste).
_RESIDUAL_SLOP = (
    "cinematic", "epic", "stunning", "amazing", "breathtaking",
    "masterpiece", "gorgeous", "magnificent", "spectacular",
    "incredible", "awesome", "ultra-detailed", "highly detailed",
    "award-winning",
)

# Hard-Block-Tokens (Apiyi: 'fast' erzeugt Jitter).
_HARD_BLOCK = ("fast", "very fast", "super fast", "lightning fast")

# Meta-Anweisungen, die der Strip im Idealfall entfernt hat. Wenn im
# finalen Prompt noch da -> Builder hat versagt.
_META_PATTERNS = (
    r"\bthis\s+is\s+(?:the\s+)?(?:first|start|beginning|opening)\s+frame\b",
    r"\bstrict[:\s]+no\b",
    r"\bit\s+is\s+not\s+(?:a\s+)?(?:static|still|comic|drawing)\b",
    r"\b(?:please|try\s+to|if\s+possible)\b",
)

# Numerierte Storyboard-Labels (1. MOTIV:, 5. LICHT:).
_NUMBERED_LABEL_RE = re.compile(r"\b\d+\.\s*[A-Z][A-Z/\-_]+[A-Z]:\s*")

# Technisches Lingo.
_TECH_LINGO_RE = re.compile(
    r"\b(?:\d+\s*mm|f[/.]?\d+(?:\.\d+)?|iso\s*\d+|\d+\s*fps|\d+\s*°)\b",
    re.IGNORECASE,
)

# Negationswoerter. Bild-/Videomodelle (Gemini/Nano Banana, Seedance
# 2.0) verarbeiten Negativ-Prompting schlecht oder gar nicht: das Token
# nach der Verneinung wird oft trotzdem aktiviert oder das Modell
# ignoriert die Verneinung. Pflicht: positive Beschreibung des
# erwuenschten Zustands. Der Linter flaggt jede Negation im finalen
# Provider-Prompt.
_NEGATION_PATTERN = re.compile(
    r"\b(no|not|avoid|without|kein|keine)\b",
    re.IGNORECASE,
)

# Triptychon-Trigger-Words — wenn im Prompt enthalten OHNE Single-
# Output-Direktive, sehr riskant.
_GRID_TRIGGERS = ("panel", "panels", "triptych", "grid", "split screen", "sheet")

# Single-Output-Direktive — eine der Phrasen muss bei Multi-Ref-Prompts
# drin sein. Positive Varianten dazu, die alte Negativ-Form ("not a
# triptych", "not a grid") wird vom Builder nicht mehr ausgegeben —
# Pattern bleibt fuer Linter-Backward-Kompat.
_SINGLE_OUTPUT_PATTERNS = (
    r"single\s+full[-\s]frame\s+image",
    r"unified\s+continuous\s+picture",
    r"edge[-\s]to[-\s]edge",
    r"not\s+a\s+triptych",
    r"not\s+a\s+grid",
    r"output\s+one\s+image",
)


def lint_prompt(
    provider_prompt: str,
    *,
    multi_ref_hints: list[str] | None = None,
    reference_paths: list[Path] | None = None,
    min_length: int = 40,
) -> list[LintFinding]:
    """Linter-Befund-Liste fuer einen gebauten provider_prompt.

    Args:
        provider_prompt: der String, der gleich an den Provider geht.
        multi_ref_hints: die Hint-Liste, die uebergeben wurde — fuer
            Cross-Check, ob die "Image N:"-Reihenfolge im Prompt damit
            uebereinstimmt.
        reference_paths: lokale Reference-Image-Pfade fuer den Content-
            Block-Pfad-Check.
        min_length: untere Schranke fuer "kein leerer Prompt".

    Returns:
        Liste von LintFinding. Schwellen-Logik (errors blocken, warns
        loggen) ist Caller-Sache.
    """
    out: list[LintFinding] = []
    p = provider_prompt or ""
    p_low = p.lower()

    # 1. Leer / zu kurz
    if len(p.strip()) < min_length:
        out.append(LintFinding(
            "error", "PROMPT_TOO_SHORT",
            f"Final prompt is {len(p.strip())} chars (< {min_length}). "
            "Builder hat vermutlich keinen Subject bekommen oder Slop-"
            "Strip hat alles weggeloescht."
        ))
        # Bei leerem Prompt weitere Checks sinnlos
        if len(p.strip()) == 0:
            return out

    # 2. Doppelter Style-Tag
    style_count = len(re.findall(r"\bStyle:\s", p))
    if style_count > 1:
        out.append(LintFinding(
            "error", "DOUBLE_STYLE_TAG",
            f"'Style:' kommt {style_count}x im Prompt vor. Builder muss "
            "Style-Slot ueberspringen, wenn Subject bereits Style nennt. "
            "Style-Drift im Output sehr wahrscheinlich."
        ))

    # 3. Slop ueberlebt
    for tok in _RESIDUAL_SLOP:
        if re.search(rf"\b{re.escape(tok)}\b", p_low):
            out.append(LintFinding(
                "warn", "RESIDUAL_SLOP",
                f"Slop-Token {tok!r} ist im finalen Prompt — Strip hat "
                "es uebersehen. Output wird Richtung Generic-Stockfoto "
                "gezogen."
            ))
            break  # einmal pro Prompt reicht

    # 4. Hard-Block-Tokens (Apiyi: 'fast' = Jitter)
    for tok in _HARD_BLOCK:
        if re.search(rf"\b{re.escape(tok)}\b", p_low):
            out.append(LintFinding(
                "error", "HARD_BLOCK_TOKEN",
                f"Hard-Block-Token {tok!r} ist im finalen Prompt — "
                "Apiyi-Guide: erzeugt reproduzierbar Jitter."
            ))
            break

    # 5. Meta-Anweisungen ueberlebt
    for pat in _META_PATTERNS:
        if re.search(pat, p, flags=re.IGNORECASE):
            out.append(LintFinding(
                "error", "META_INSTRUCTION_SURVIVED",
                f"Meta-Anweisung matched Pattern {pat!r} — Strip hat "
                "es nicht erwischt. Modell wird verwirrt."
            ))
            break

    # 6. Numerierte Labels
    if _NUMBERED_LABEL_RE.search(p):
        m = _NUMBERED_LABEL_RE.search(p)
        out.append(LintFinding(
            "error", "NUMBERED_LABEL_SURVIVED",
            f"Numeriertes Storyboard-Label {m.group(0)!r} im finalen "
            "Prompt — Strip hat versagt. Modell sieht Storyboard-"
            "Vokabular, neigt zu Multi-Panel-Output."
        ))

    # 7. Technisches Lingo
    m = _TECH_LINGO_RE.search(p)
    if m:
        out.append(LintFinding(
            "warn", "TECH_LINGO_SURVIVED",
            f"Technisches Lingo {m.group(0)!r} im finalen Prompt — "
            "Modell parst das nicht. Strip uebersehen."
        ))

    # 8. Lighting-Marker fehlt
    if not any(mark in p_low for mark in _LIGHT_MARKERS):
        out.append(LintFinding(
            "warn", "MISSING_LIGHTING",
            "Kein Lighting-Marker im finalen Prompt. Apiyi: hoechster "
            "Quality-Hebel — ohne Lighting wird Output generisch."
        ))

    # 9. Grid-Trigger ohne Single-Output-Direktive
    has_grid_trigger = any(re.search(rf"\b{re.escape(t)}\b", p_low)
                           for t in _GRID_TRIGGERS)
    has_single_output = any(re.search(pat, p_low)
                            for pat in _SINGLE_OUTPUT_PATTERNS)
    if has_grid_trigger and not has_single_output:
        out.append(LintFinding(
            "warn", "GRID_TRIGGER_WITHOUT_SINGLE_OUTPUT_DIRECTIVE",
            "Prompt enthaelt grid-/panel-/sheet-Trigger, aber keine "
            "Single-Output-Direktive ('single full-frame image', 'not a "
            "triptych'). Triptychon-Risiko."
        ))

    # 10. Multi-Ref: Single-Output-Direktive fast immer noetig
    if multi_ref_hints and len(multi_ref_hints) >= 2 and not has_single_output:
        out.append(LintFinding(
            "error", "MULTIREF_WITHOUT_SINGLE_OUTPUT_DIRECTIVE",
            f"{len(multi_ref_hints)} References im Call, aber keine "
            "Single-Output-Direktive im Prompt. Gemini 3 Pro Image "
            "neigt empirisch zu Composite/Collage bei 2+ Refs ohne "
            "explizite Anti-Grid-Klausel."
        ))

    # 11. Negationen im finalen Prompt.
    # Bild-/Videomodelle aktivieren das Token trotz Verneinung — der
    # Linter listet alle Treffer auf, damit Builder-Aenderungen keine
    # Negationen wieder einschmuggeln.
    neg_hits = sorted({m.group(0).lower() for m in _NEGATION_PATTERN.finditer(p)})
    if neg_hits:
        out.append(LintFinding(
            "warn", "PROMPT_CONTAINS_NEGATION",
            f"Final prompt enthaelt Negation(en): {neg_hits}. Image-/"
            "Videomodelle ignorieren oder verstaerken Negationen — "
            "stattdessen den ERWUENSCHTEN Zustand positiv beschreiben "
            "(siehe builder._positive_phrasing-Tabelle)."
        ))

    # 12. Ref-Hint-Count vs. tatsaechliche "Image N:"-Eintraege
    if multi_ref_hints:
        image_n = sorted(set(int(m.group(1))
                             for m in re.finditer(r"Image\s+(\d+):", p)))
        expected = list(range(1, len(multi_ref_hints) + 1))
        if image_n and image_n != expected:
            out.append(LintFinding(
                "warn", "REF_HINT_INDEX_MISMATCH",
                f"Image-Indices im Prompt={image_n}, erwartet={expected}. "
                "Builder-Bug oder Reihenfolge wurde manipuliert."
            ))

    # 13. Content-Block-Risiko.
    # Erkennt typische Seedance-Filter-Trigger (Gewalt-Vokabular,
    # Real-Personen-Namen, Brand-Tokens). Findings werden in den
    # gleichen LintFinding-Stream geleitet, behalten ihren Block-Code.
    from nexgen_engine.render.prompt.content_block_linter import (
        lint_reference_paths as _lint_block_paths,
        lint_provider_prompt as _lint_block,
    )
    for br in _lint_block(p):
        out.append(LintFinding(
            br.severity, br.code,
            br.message + f" (Umschreib-Vorschlag: '{br.suggestion}')",
        ))
    if reference_paths:
        for br in _lint_block_paths(reference_paths):
            out.append(LintFinding(
                br.severity, br.code,
                br.message + f" (Umschreib-Vorschlag: '{br.suggestion}')",
            ))

    return out


def format_findings(findings: list[LintFinding]) -> str:
    """Pretty-Print fuer CLI-Output."""
    if not findings:
        return "lint clean: keine Befunde."
    lines = [f"{len(findings)} Befunde:"]
    for f in findings:
        marker = {"error": "✗", "warn": "!", "info": "i"}[f.severity]
        lines.append(f"  {marker} [{f.severity.upper()}] {f.code}: {f.message}")
    return "\n".join(lines)


def has_blocking(findings: list[LintFinding]) -> bool:
    return any(f.severity == "error" for f in findings)
