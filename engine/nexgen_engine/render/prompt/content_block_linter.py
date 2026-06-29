"""Content-Block-Risiko-Linter.

Hintergrund-Recherche 2026-06: ByteDance Seedance 2.0 hat drei
Moderation-Filter (Prompt + Face-Upload + Output), die NICHT
provider-spezifisch sind. Egal ob fal.ai, Runway, Atlas Cloud,
WaveSpeed, Replicate oder ByteDance direkt — derselbe Provider blockt
dieselbe Sache, weil das Modell die Moderation traegt.

Empirisch belegte Block-Trigger:

1. **Gewalt-Vokabular im Prompt-Text** — "shoot", "kill", "stab",
   "blood", "weapon", "gun", "knife". Pattern-Filter macht das per
   English-Keyword-Match. Umgehbar mit Synonymen: "tactical gear",
   "muzzle flash", "smoke trails", "fallen figure".

2. **Real-Personen-Namen** — Politiker, Promis, Athleten. Filter
   detektiert explizite Namens-Referenzen UND stilistische
   Beschreibungen, die offensichtlich auf bekannte Personen zeigen.

3. **Brand-/IP-Tokens** — Markenlogos, Disney-Charaktere, Sport-
   Vereinslogos, etc. Output-Filter schmeisst auch geblurrte Brand-
   Treffer raus.

4. **Real-Photo-Faces als Reference** — Face-Upload-Filter blockt
   "echte" Gesichter, laesst AI-generated / illustrated / 3D-Render
   / cel-shaded / side-profile-mit-wenig-Gesichtsdetail durch.

Dieser Linter checkt den finalen Provider-Prompt (string) PLUS
optional eine Liste an Reference-Image-Pfaden auf typische Block-
Trigger, BEVOR der teure Render-Call ausgeloest wird. Trefferquote
ist nicht perfekt — Seedance-Filter selber hat False-Positives, der
Linter ist konservativ (zeigt Risiken, blockt nicht hart).
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Literal


Severity = Literal["error", "warn", "info"]


@dataclass(frozen=True)
class BlockRiskFinding:
    severity: Severity
    code: str
    matched: str
    suggestion: str
    message: str


# Gewalt-/Waffen-Keywords (English, das ist Seedance-Filter-Sprache)
_VIOLENCE_KEYWORDS: tuple[tuple[str, str], ...] = (
    # (Keyword, Umschreibungsvorschlag)
    ("shoot", "muzzle flash, tactical gesture"),
    ("shooting", "muzzle flash sequence"),
    ("shot dead", "fallen figure, motionless"),
    ("kill", "subdue, take down"),
    ("killed", "subdued, taken down"),
    ("murder", "violent confrontation aftermath"),
    ("stab", "lunge with sharp object"),
    ("stabbed", "lunged-at, struck"),
    ("blood", "dark stain, red fluid"),
    ("bloody", "stained, marked"),
    ("weapon", "tactical implement"),
    ("gun", "tactical sidearm"),
    ("rifle", "long-barreled implement"),
    ("pistol", "compact tactical implement"),
    ("revolver", "compact tactical sidearm"),
    ("firearm", "tactical implement"),
    ("shotgun", "long-barreled implement"),
    ("holster", "side pouch"),
    ("knife", "sharp implement"),
    ("dead body", "still figure on the ground"),
    ("corpse", "still figure"),
    ("dying", "weakening, fading"),
    ("execute", "subdue dramatically"),
    ("attack", "confront aggressively"),
    # Aktions-Verben rund um Waffen. Bewusst als Multi-Word-Patterns,
    # damit Single-Token-False-Positives vermieden werden ("aim of the
    # song", "cocked head", "drew breath"). `muzzle` ist NICHT in der
    # Liste, weil der eigene Workaround "muzzle flash, tactical gear"
    # sonst sich selbst flaggt.
    ("aim at", "gesture toward, focus attention on"),
    ("aimed at", "gestured toward, focused on"),
    ("aiming at", "gesturing toward"),
    ("point gun", "raise tactical implement"),
    ("pointing gun", "raising tactical implement"),
    ("draw weapon", "produce tactical implement"),
    ("drew weapon", "produced tactical implement"),
    ("cocked gun", "ready tactical implement"),
    ("loaded gun", "ready tactical implement"),
    ("loaded weapon", "ready tactical implement"),
)


# Real-Personen-Namen — keine vollstaendige Liste, klar bekannte
# Beispiel-Bereiche zur Demonstration. User-Erweiterung via
# `BLOCK_RISK_EXTRA_NAMES`-Env-Var (kuenftig).
_REAL_NAMES_HINTS: tuple[tuple[str, str], ...] = (
    # (Pattern, Begruendung)
    (r"\b(Donald\s+Trump|Joe\s+Biden|Barack\s+Obama|Kamala\s+Harris)\b",
     "US-politische Person"),
    (r"\b(Vladimir\s+Putin|Volodymyr\s+Zelensky|Xi\s+Jinping)\b",
     "geopolitische Person"),
    (r"\b(Taylor\s+Swift|Beyonc[eé]|Drake|Kanye\s+West)\b",
     "Pop-Promi"),
    (r"\b(Elon\s+Musk|Mark\s+Zuckerberg|Jeff\s+Bezos)\b",
     "Tech-CEO"),
    (r"\b(Lebron\s+James|Cristiano\s+Ronaldo|Lionel\s+Messi)\b",
     "Sport-Promi"),
)


# Brand-/IP-Tokens — Top-Tier Risiko-Kandidaten.
_BRAND_TOKENS: tuple[tuple[str, str], ...] = (
    # (Pattern, Umschreibungsvorschlag)
    (r"\bNike\b", "athletic-brand sneakers"),
    (r"\bAdidas\b", "three-stripe athletic-brand sneakers"),
    (r"\bMcDonald'?s\b", "fast-food restaurant"),
    (r"\bCoca[-\s]?Cola\b", "red soda can"),
    (r"\bPepsi\b", "blue soda can"),
    (r"\bStarbucks\b", "coffee chain cafe"),
    (r"\bApple(?:\s+iPhone)?\b", "smartphone"),
    (r"\bGoogle\b", "search-engine browser tab"),
    (r"\bTwitter\b", "microblog-service feed"),
    (r"\bFacebook\b", "social-network feed"),
    (r"\bInstagram\b", "social-photo-app feed"),
    (r"\bDisney(?:land|world)?\b", "themepark"),
    (r"\bMickey\s+Mouse\b", "stylized cartoon mouse character"),
    (r"\bSpider[-\s]?Man\b", "masked acrobatic hero"),
    (r"\bBatman\b", "caped vigilante in dark armor"),
    (r"\bSuperman\b", "caped hero in primary-colors costume"),
    (r"\bPok[eé]mon\b", "stylized creature character"),
    (r"\bMario(?:\s+Bros)?\b", "plumber-style platformer character"),
    (r"\bLego\b", "interlocking-brick figure"),
)


# Real-Photo-Indikatoren in Reference-Pfaden
_REAL_PHOTO_PATH_HINTS: tuple[str, ...] = (
    "photo",
    "photograph",
    "selfie",
    "real_person",
    "real-person",
    "headshot",
    "portrait_real",
)


# Multi-Char-Risiko ist framing-AGNOSTISCH — wir unterscheiden nur noch
# in zwei Risiko-Stufen (high/wide), beide werden geflaggt.
#
# Empirie-Update (Juni 2026):
#
# Eine fruehere Annahme war "WIDE side-by-side ohne Kontakt" sei ein
# zuverlaessiger Workaround — n=2 (zwei durchgekommene WIDE-Shots)
# wurde mit "robust" verwechselt. Folge-Empirie:
#
# - s027 als WIDE reframed (ruhig, side-by-side, Gap, entwaffnet) →
#   trotzdem content_policy_violation. Fast identisch zu s030, das
#   durchging.
# - s009, s022: ebenfalls WIDE, Two-Char, geblockt.
# - s030, s032: WIDE, Two-Char, durchgekommen.
# - Ueber alle Zwei-Char-Versuche: ~22, davon 2 erfolgreich.
#   p_fail ≈ 0.91, **weitgehend framing-unabhaengig**.
#
# Interpretation: der ByteDance-Output-Classifier triggert auf die
# **Praesenz** zweier anthropomorpher Figuren, nicht auf deren
# Groesse/Framing. WIDE reduziert die Wahrscheinlichkeit etwas
# (schaetzungsweise ~50% Block vs ~90% Block bei nahen Framings),
# bleibt aber kein verlaessliches Werkzeug.
#
# Folge: alle Multi-Char-Shots werden geflaggt, mit differenzierter
# Meldung pro Risiko-Stufe.
_MULTI_CHAR_HIGH_RISK_FRAMINGS: frozenset[str] = frozenset({
    "ms", "mcu", "cu", "ecu", "ots",
})

# WIDE-Tier-Framings: zeigen die Figuren klein/distanziert, Block-Rate
# empirisch niedriger, aber nicht verlaesslich. Andere Framings, die
# Multi-Char ueberhaupt zeigen koennen, fallen ebenfalls hier rein.
# `INSERT` und `AERIAL` bleiben ausserhalb der Pruefung, weil sie
# selten Figuren in voller Komposition zeigen (Insert = Detail-Shot,
# Aerial = Vogelperspektive auf Welt).
_MULTI_CHAR_WIDE_TIER_FRAMINGS: frozenset[str] = frozenset({
    "wide", "full", "pov",
})


# Visual-Media, in denen der Anthro-Output-Filter-Trigger empirisch
# auftritt. Cartoon/Animation/3D-CG/Stop-Motion produzieren
# anthropomorphe figuerliche Gestalt-Paare, die der ByteDance-Output-
# Classifier als Risiko bewertet. Live-Action (realistic + stylized)
# zeigt **Menschen**, kein anthropomorphes Tier-/Comic-Paar — der
# Filter triggert dort nicht. Ohne dieses Gate wuerde der Check
# Two-Char-MS-Dialog in jedem Live-Action-Brief unnoetig flaggen.
#
# `OTHER` und `MIXED` werden konservativ als at-risk behandelt, weil
# der Skill nicht sicher wissen kann ob der Brief anthropomorph ist.
# `None` (Brief noch nicht da / nicht uebergeben) → at-risk (bisheriges
# Verhalten, Backward-Kompat).
_AT_RISK_VISUAL_MEDIA: frozenset[str] = frozenset({
    "3d_cg",
    "2d_animation",
    "illustration",
    "stop_motion",
    "mixed",
    "other",
})


def lint_shot_for_multi_character_block(
    character_refs: list[str],
    framing: object | None,
    visual_medium: object | None = None,
) -> list[BlockRiskFinding]:
    """Strukturfeld-Check fuer den Anthro-Multi-Char-False-Positive
    (framing-agnostisch).

    Empirie (Juni 2026):

    - ~22 Zwei-Char-Versuche, 2 Erfolge → p_fail ≈ 0.91.
    - Framing macht einen Risiko-Unterschied, aber keinen Lösungs-
      Unterschied:
        * Nahe Framings (MS/MCU/CU/ECU/OTS): empirisch ~90% Block.
        * WIDE/FULL/POV Multi-Char-Shots: empirisch ~50% Block.
    - s027 wurde explizit als WIDE + ruhig + side-by-side + Gap +
      entwaffnet getestet und trotzdem geblockt — gleiche
      Komposition wie das durchgekommene s030. Sample-Stochastik,
      keine sichere Heuristik.
    - Token-Linter (Prompt + Pfade) war auf allen Fehl-Shots CLEAN.
      Der Trigger ist visuelle Gestalt (Anthro-Paar im Bild),
      kein Text-Pattern.

    Regel: jeder Shot mit `>=2 character_refs` UND `visual_medium`
    im at-risk-Set wird geflaggt. Severity = warn — n=1 Projekt,
    Validierung an einem zweiten Fall steht aus.

    Tier-Differenzierung in der Meldung:
    - `high_risk` (MS/MCU/CU/ECU/OTS): ~90% Block-Rate.
    - `wide_tier` (WIDE/FULL/POV): ~50% Block-Rate.
    - Sonstige (INSERT/AERIAL): ueberspringen — diese Framings
      zeigen Figuren in der Regel nicht in voller Komposition.
    - None: ueberspringen.

    Visual-Medium-Gate: Live-Action-Briefs sind exemt. Der Filter
    triggert auf anthropomorphe Tier-/Comic-Paare, nicht auf echte
    Menschen.

    Args:
        character_refs: Liste der Bible-Character-IDs des Shots.
        framing: `Shot.framing` (Framing-Enum oder None). Akzeptiert
            Enum mit `.value` oder Plain-String. None oder framing
            ausserhalb high/wide-Tier → keine Pruefung.
        visual_medium: `Brief.visual_medium`. None → at-risk-Default
            (Backward-Kompat). Live-Action raus.
    """
    out: list[BlockRiskFinding] = []
    n = len(character_refs or [])
    if n < 2:
        return out
    if framing is None:
        return out
    framing_val = (
        framing.value if hasattr(framing, "value") else str(framing)
    ).lower()
    if framing_val in _MULTI_CHAR_HIGH_RISK_FRAMINGS:
        tier = "high"
    elif framing_val in _MULTI_CHAR_WIDE_TIER_FRAMINGS:
        tier = "wide"
    else:
        # INSERT/AERIAL/unbekannt — keine Pruefung
        return out
    # Visual-Medium-Gate. Wenn None → at-risk-Default (Backward-Kompat,
    # bisherige Aufrufer ohne den Param sehen kein Verhalten-Drift).
    if visual_medium is not None:
        vm_val = (
            visual_medium.value
            if hasattr(visual_medium, "value")
            else str(visual_medium)
        )
        if vm_val.lower() not in _AT_RISK_VISUAL_MEDIA:
            return out
    if tier == "high":
        rate_text = "~90% Block-Rate"
        framing_note = "(nahe Framings triggern den Filter besonders zuverlaessig)"
    else:
        rate_text = "~50% Block-Rate"
        framing_note = (
            "(WIDE/FULL/POV reduziert das Risiko, eliminiert es aber "
            "NICHT — s027-wide wurde explizit getestet und trotzdem "
            "geblockt; nicht als zuverlaessiger Workaround verwenden)"
        )
    out.append(BlockRiskFinding(
        severity="warn",
        code="BLOCKING_RISK_MULTI_CHARACTER",
        matched=f"{n} character_refs in framing={framing_val} [{tier}-tier]",
        suggestion=(
            "(a) Single-Character Schuss/Gegenschuss "
            "(p_fail≈0, primary), oder "
            "(c) Still-Frame + Ken-Burns/Pan-Zoom im NLE "
            "(nur nach User-Approval, Minimum-Einsatz, "
            "Ruhepositionen, in Live-Action nur ohne Menschen "
            "im Frame — Pflicht-Bedingungen siehe Shotlist-Doku "
            "Block -2)"
        ),
        message=(
            f"Shot hat {n} character_refs (framing={framing_val}, "
            f"{tier}-tier, {rate_text}) — der ByteDance-Output-Filter "
            "triggert auf die Praesenz anthropomorpher Figuren-Paare, "
            f"framing-weitgehend-unabhaengig. {framing_note}. "
            "Token-Linter sieht das nicht (rein visuelle Gestalt). "
            "Verlaessliche Loesungen: "
            "(a) Shot splitten in Single-Char-Schuss + Gegenschuss "
            "(p_fail≈0 bei Single-Char). "
            "(c) Still-Frame im Image-Modell generieren (Image-Pfad "
            "hat vermutlich den Seedance-Video-Output-Filter NICHT — "
            "noch nicht empirisch verifiziert) und Bewegung "
            "via Ken-Burns/Pan-Zoom im NLE (FCP/DaVinci) machen. "
            "(c) braucht User-Approval, Minimum-Einsatz, "
            "Ruhepositionen; in Live-Action nur ohne Menschen im "
            "Frame. Marker: `still_only_approved:` in Shot.notes. "
            "NICHT empfohlen: WIDE-Reframing (s.o.) und Brute-Force-"
            "Retry (p_fail≈0.91 → ~21 Retries fuer 85% Confidence, "
            "unwirtschaftlich trotz 0-EUR-Fails)."
        ),
    ))
    return out


def lint_provider_prompt(prompt: str) -> list[BlockRiskFinding]:
    """Linter fuer den fertig gebauten Provider-Prompt.

    Erkennt Gewalt-Tokens, Real-Personen-Namen und Brand-Tokens.
    Liefert eine Liste an Findings mit Umschreibungsvorschlag.
    """
    out: list[BlockRiskFinding] = []
    text = prompt or ""
    text_low = text.lower()

    # 1. Gewalt-Keywords (mit Verb-Inflektion: shoot/shoots/shooting,
    # kill/kills/killing, etc.)
    seen_violence: set[str] = set()
    for kw, suggestion in _VIOLENCE_KEYWORDS:
        if kw in seen_violence:
            continue
        # Erlaube optional -s, -ing, -ed nach dem Wort-Stamm
        if " " in kw:
            # Mehrwort-Pattern — exakter Match, keine Inflektion
            pattern = rf"\b{re.escape(kw)}\b"
        else:
            pattern = rf"\b{re.escape(kw)}(?:s|es|ing|ed)?\b"
        if re.search(pattern, text_low):
            out.append(BlockRiskFinding(
                severity="warn",
                code="BLOCKING_RISK_VIOLENCE",
                matched=kw,
                suggestion=suggestion,
                message=(
                    f"Gewalt-Token {kw!r} im Prompt — Seedance-Prompt-"
                    f"Filter blockt oder restringiert dieses Pattern. "
                    f"Umschreib-Vorschlag: '{suggestion}'."
                ),
            ))
            seen_violence.add(kw)

    # 2. Real-Namen
    for pattern, kind in _REAL_NAMES_HINTS:
        m = re.search(pattern, text, flags=re.IGNORECASE)
        if m:
            out.append(BlockRiskFinding(
                severity="warn",
                code="BLOCKING_RISK_REAL_NAME",
                matched=m.group(0),
                suggestion="fictional figure described by attributes only",
                message=(
                    f"Real-Personen-Token {m.group(0)!r} ({kind}) im "
                    f"Prompt — Seedance blockt das fast immer. Lese: "
                    "fiktive Figur ueber Attribute beschreiben (Alter, "
                    "Statur, Kleidung) statt namentlich."
                ),
            ))

    # 3. Brand-Tokens
    for pattern, suggestion in _BRAND_TOKENS:
        m = re.search(pattern, text, flags=re.IGNORECASE)
        if m:
            out.append(BlockRiskFinding(
                severity="warn",
                code="BLOCKING_RISK_BRAND",
                matched=m.group(0),
                suggestion=suggestion,
                message=(
                    f"Brand/IP-Token {m.group(0)!r} im Prompt — "
                    "Output-Filter blockt typischerweise. Umschreib-"
                    f"Vorschlag: '{suggestion}'."
                ),
            ))

    return out


def lint_reference_paths(paths: list[Path]) -> list[BlockRiskFinding]:
    """Linter-Check auf Real-Photo-Indikatoren in Reference-Image-Pfaden.

    Heuristik: Pfad-Bestandteile mit 'photo'/'selfie'/'headshot' deuten
    auf echte Photos hin. Face-Upload-Filter blockt Real-Photo-Faces;
    AI-generated/illustrated/stylized sind durchlassig.
    """
    out: list[BlockRiskFinding] = []
    for p in paths:
        path_str = str(p).lower()
        for hint in _REAL_PHOTO_PATH_HINTS:
            pattern = rf"(?<![a-z0-9]){re.escape(hint)}(?![a-z0-9])"
            if re.search(pattern, path_str):
                out.append(BlockRiskFinding(
                    severity="warn",
                    code="BLOCKING_RISK_REAL_PHOTO_REFERENCE",
                    matched=str(p),
                    suggestion=(
                        "AI-generated, illustrated, cel-shaded or 3D-rendered "
                        "version of the same character"
                    ),
                    message=(
                        f"Reference-Pfad {p} enthaelt {hint!r} — Face-"
                        "Upload-Filter blockt Real-Photo-Faces. Lese: "
                        "Bible-Sheet im illustrierten Stil rendern (Bible-"
                        "Style-Guide), echte Photos nur als private "
                        "Recherche-Quelle behalten."
                    ),
                ))
                break  # nur einen Treffer pro Pfad
    return out


def format_findings(findings: list[BlockRiskFinding]) -> str:
    if not findings:
        return "kein Block-Risiko erkannt."
    lines = [f"{len(findings)} potenzielle Block-Risiken:"]
    for f in findings:
        marker = {"error": "✗", "warn": "!", "info": "i"}[f.severity]
        lines.append(f"  {marker} [{f.severity.upper()}] {f.code}: {f.message}")
    return "\n".join(lines)


def has_blocking_risk(findings: list[BlockRiskFinding]) -> bool:
    """True wenn mindestens ein error-Severity-Finding dabei ist."""
    return any(f.severity == "error" for f in findings)
