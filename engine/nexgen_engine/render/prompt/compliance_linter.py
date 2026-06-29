"""Compliance-Linter.

Prueft, ob der gebaute Provider-Prompt zur Shot-Spec passt. Faengt
die Klasse von Drifts ab, wo der Project-Agent (oder ein
schwammig formulierter visual_prompt) Tokens erzeugt, die mit
camera_setup / framing / character_blocking / Section-Kontext nicht
zusammen passen.

Beispiel-Befund: ein visual_prompt enthielt "looking off toward the
horizon" + Sonnenuntergang-Sprache, obwohl die Story Tag-Setting hatte
und das Schluss-Tableau weder Sonnenuntergang noch Horizont-Blick
verlangte. Der Token-Linter hat das nicht gefangen, weil er nur
Stil-Slop / Negationen / Block-Vokabular prueft.

Heuristik-Set:

1. CAMERA_HEIGHT_MISMATCH — Prompt enthaelt "aerial view",
   "overhead", "top down", "bird's eye" obwohl
   shot.camera_setup.height = eye_level/low/knee/worm.
2. CAMERA_LOW_HIGH_MISMATCH — Prompt enthaelt "low angle",
   "looking up", "from below" obwohl height = high/overhead, oder
   "high angle", "looking down" obwohl height = low/worm.
3. FRAMING_MISMATCH — Prompt enthaelt Close-Up-Wortschatz
   ("close-up", "extreme close-up", "detail of his face") obwohl
   framing in {WIDE, FULL, AERIAL}, ODER Wide-Wortschatz
   ("wide shot", "establishing", "from far away") obwohl framing
   in {CU, ECU, MCU, INSERT}.
4. GAZE_MISMATCH — Prompt enthaelt Blick-Tokens, die nicht zur
   character_blocking[].gaze passen (z.B. "looking off toward the
   horizon" obwohl gaze = "at notebook").
5. SETTING_DRIFT — Prompt enthaelt Zeit-/Lighting-Tokens
   (sunset, sunrise, golden hour, dusk, dawn, twilight, midnight,
   nighttime, moonlit), obwohl die Shot-Spec / Section-Kontext kein
   solches Setting verlangt. Heuristik kann Section/Brief nicht
   tief verstehen — flaggt erstmal das Vorhandensein dieser Tokens,
   damit der Project-Agent + User es bewusst pruefen.

Alle Findings sind warn.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Token-Pattern (case-insensitive, Wortgrenzen)
# ---------------------------------------------------------------------------

_AERIAL_TOKENS = re.compile(
    r"\b(aerial(?:\s+view)?|bird'?s[\s-]?eye|top[\s-]?down|drone\s+shot|overhead)\b",
    re.IGNORECASE,
)
_LOW_ANGLE_TOKENS = re.compile(
    r"\b(low\s+angle|from\s+below|looking\s+up|ground[\s-]?level|worm'?s[\s-]?eye)\b",
    re.IGNORECASE,
)
_HIGH_ANGLE_TOKENS = re.compile(
    r"\b(high\s+angle|looking\s+down|down\s+at|from\s+above)\b",
    re.IGNORECASE,
)

_CLOSE_UP_TOKENS = re.compile(
    r"\b(close[\s-]?up|extreme\s+close[\s-]?up|tight\s+on|detail\s+of\s+(?:his|her|their)\s+(?:face|eyes|hand|hands))\b",
    re.IGNORECASE,
)
_WIDE_TOKENS = re.compile(
    r"\b(wide\s+shot|establishing\s+shot|from\s+far\s+away|long\s+shot|full[\s-]?body\s+shot)\b",
    re.IGNORECASE,
)

_GAZE_TOKENS = re.compile(
    r"\b(?:looking|gazing|staring|peering|glancing)\s+(?:off\s+)?(?:toward|towards|at|into|over|across|away|down|up|out)(?:\s+\w+)?",
    re.IGNORECASE,
)

# Setting-/Lighting-Tokens, die fast immer eine bewusste Story-Entscheidung
# sein muessen, nicht aus der Huefte gepromtet.
_SETTING_TOKENS = re.compile(
    r"\b(sunset|sunrise|golden\s+hour|magic\s+hour|dusk|dawn|twilight|midnight|nighttime|night[\s-]?time|moonlit|moonlight|blue\s+hour|harsh\s+noon|backlit\s+silhouette)\b",
    re.IGNORECASE,
)


# Welche Framings sind "weit" (Close-Up-Tokens verboten)?
_WIDE_FAMILY_FRAMINGS: frozenset[str] = frozenset({"wide", "full", "aerial"})
# Welche Framings sind "nah" (Wide-Tokens verboten)?
_CLOSE_FAMILY_FRAMINGS: frozenset[str] = frozenset({"cu", "ecu", "mcu", "insert"})

# Camera-Heights, bei denen aerial/overhead-Tokens NICHT passen.
_NON_AERIAL_HEIGHTS: frozenset[str] = frozenset(
    {"eye_level", "low", "knee", "worm"}
)
# Heights, bei denen "low angle"-Tokens NICHT passen.
_NON_LOW_HEIGHTS: frozenset[str] = frozenset({"high", "overhead"})
# Heights, bei denen "high angle"-Tokens NICHT passen.
_NON_HIGH_HEIGHTS: frozenset[str] = frozenset({"low", "worm", "knee"})


@dataclass(slots=True)
class ComplianceFinding:
    severity: str  # 'warn'
    code: str
    matched: str
    message: str


def _enum_val(value) -> str | None:
    if value is None:
        return None
    return (value.value if hasattr(value, "value") else str(value)).lower()


def _camera_height(camera_setup) -> str | None:
    if camera_setup is None:
        return None
    return _enum_val(getattr(camera_setup, "height", None))


def lint_prompt_against_shot(
    provider_prompt: str,
    shot,
) -> list[ComplianceFinding]:
    """Prueft den fertig gebauten Provider-Prompt gegen die Shot-Spec.

    Ruft alle Heuristiken durch und sammelt Findings als `warn`.
    Aufrufer entscheidet ob der Render-Pfad blockiert wird (die
    Frame-Phase-Doku triggert Pre-Generation-Review bei warn-Findings).

    Args:
        provider_prompt: Output von `build_image_prompt(...)`.
        shot: Shot-Pydantic-Instanz mit framing/camera_setup/
            character_blocking-Feldern.
    """
    out: list[ComplianceFinding] = []
    text = provider_prompt or ""

    framing_val = _enum_val(getattr(shot, "framing", None))
    height_val = _camera_height(getattr(shot, "camera_setup", None))
    blocking = getattr(shot, "character_blocking", None) or []

    # --- 1. Camera-Height vs aerial/overhead ---------------------------
    m = _AERIAL_TOKENS.search(text)
    if m and height_val in _NON_AERIAL_HEIGHTS:
        out.append(ComplianceFinding(
            severity="warn",
            code="CAMERA_HEIGHT_MISMATCH",
            matched=m.group(0),
            message=(
                f"Provider-Prompt enthaelt {m.group(0)!r}, aber "
                f"shot.camera_setup.height = {height_val!r}. Aerial/"
                f"overhead-Tokens widersprechen einer eye-level/low-"
                "Kamera. Entweder Prompt anpassen oder camera_setup "
                "in der Shotlist auf high/overhead aendern."
            ),
        ))

    # --- 2. Low-Angle vs height ----------------------------------------
    m = _LOW_ANGLE_TOKENS.search(text)
    if m and height_val in _NON_LOW_HEIGHTS:
        out.append(ComplianceFinding(
            severity="warn",
            code="CAMERA_LOW_HIGH_MISMATCH",
            matched=m.group(0),
            message=(
                f"Provider-Prompt enthaelt {m.group(0)!r} (low angle), "
                f"aber shot.camera_setup.height = {height_val!r}. "
                "Inkonsistent."
            ),
        ))

    m = _HIGH_ANGLE_TOKENS.search(text)
    if m and height_val in _NON_HIGH_HEIGHTS:
        out.append(ComplianceFinding(
            severity="warn",
            code="CAMERA_LOW_HIGH_MISMATCH",
            matched=m.group(0),
            message=(
                f"Provider-Prompt enthaelt {m.group(0)!r} (high angle), "
                f"aber shot.camera_setup.height = {height_val!r}. "
                "Inkonsistent."
            ),
        ))

    # --- 3. Framing vs Close/Wide-Tokens -------------------------------
    if framing_val in _WIDE_FAMILY_FRAMINGS:
        m = _CLOSE_UP_TOKENS.search(text)
        if m:
            out.append(ComplianceFinding(
                severity="warn",
                code="FRAMING_MISMATCH",
                matched=m.group(0),
                message=(
                    f"Provider-Prompt enthaelt {m.group(0)!r} "
                    f"(Close-Up-Wortschatz), aber shot.framing = "
                    f"{framing_val!r} ist Wide-Familie. Entweder "
                    "Close-Up-Tokens raus oder framing anpassen."
                ),
            ))
    if framing_val in _CLOSE_FAMILY_FRAMINGS:
        m = _WIDE_TOKENS.search(text)
        if m:
            out.append(ComplianceFinding(
                severity="warn",
                code="FRAMING_MISMATCH",
                matched=m.group(0),
                message=(
                    f"Provider-Prompt enthaelt {m.group(0)!r} "
                    f"(Wide-Wortschatz), aber shot.framing = "
                    f"{framing_val!r} ist Close-Familie."
                ),
            ))

    # --- 4. Gaze-Mismatch ----------------------------------------------
    # Wir koennen Gaze nicht semantisch verstehen — aber: wenn der
    # Prompt eine Gaze-Phrase ("looking off toward the horizon")
    # enthaelt UND character_blocking[].gaze definiert ist UND die
    # Worte nicht trivial uebereinstimmen, sollte der User pruefen.
    if blocking:
        gaze_match = _GAZE_TOKENS.search(text)
        if gaze_match:
            prompt_gaze = gaze_match.group(0).lower()
            spec_gazes = [
                (getattr(cb, "gaze", "") or "").lower()
                for cb in blocking
            ]
            spec_gazes = [g for g in spec_gazes if g]
            if spec_gazes:
                # Heuristik: wenn KEINER der spec-Gaze-Strings einen
                # nicht-trivialen Token mit dem Prompt-Gaze teilt,
                # flaggen.
                shared = False
                prompt_tokens = set(
                    t for t in re.findall(r"\w+", prompt_gaze)
                    if len(t) > 3 and t not in {
                        "look", "looks", "looking", "gaze", "gazing",
                        "staring", "stare", "toward", "towards", "into",
                        "from", "over", "across", "down",
                    }
                )
                for sg in spec_gazes:
                    sg_tokens = set(
                        t for t in re.findall(r"\w+", sg) if len(t) > 3
                    )
                    if prompt_tokens & sg_tokens:
                        shared = True
                        break
                if not shared:
                    out.append(ComplianceFinding(
                        severity="warn",
                        code="GAZE_MISMATCH",
                        matched=gaze_match.group(0),
                        message=(
                            f"Provider-Prompt enthaelt Blick-Phrase "
                            f"{gaze_match.group(0)!r}, aber keiner "
                            f"der character_blocking[].gaze-Eintraege "
                            f"({spec_gazes!r}) teilt damit ein "
                            "thematisches Wort. Pruefen: ist der "
                            "Blick im Prompt der gleiche wie in der "
                            "Spec?"
                        ),
                    ))

    # --- 5. Setting-Drift ----------------------------------------------
    # Escape: `setting_ok: <Grund>` in Shot.notes unterdrueckt das
    # Setting-Drift-Flag. Sinnvoll fuer bewusste Nacht-Szenen / Golden-
    # Hour-Briefs / Twilight-Looks, in denen das Token korrekt ist.
    notes_text = (getattr(shot, "notes", None) or "")
    setting_escape = bool(
        re.search(r"\bsetting_ok\s*:", notes_text, re.IGNORECASE)
    )
    m = _SETTING_TOKENS.search(text) if not setting_escape else None
    if m:
        out.append(ComplianceFinding(
            severity="warn",
            code="SETTING_DRIFT",
            matched=m.group(0),
            message=(
                f"Provider-Prompt enthaelt Zeit-/Lighting-Token "
                f"{m.group(0)!r}. Setting ist fast immer eine bewusste "
                "Story-Entscheidung — pruefen ob Section/Treatment "
                "diese Stimmung verlangt. Wenn nein: aus dem "
                "visual_prompt nehmen, sonst bekommt der Renderer "
                "(und der NLE-Editor bei still-only) einen "
                "Sonnenuntergang/Nacht-Block, den die Story nicht "
                "vorgesehen hat."
            ),
        ))

    return out
