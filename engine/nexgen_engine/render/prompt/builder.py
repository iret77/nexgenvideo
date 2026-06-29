"""Provider-spezifischer Prompt-Builder für Sheet- und Frame-Renders.

Ein Sheet-/Frame-Render bekommt einen `PromptPayload` (was zu zeigen
ist), die `provider` aus dem Modell-ID-Namespace und liefert einen
sauber für genau dieses Modell formulierten Prompt zurück.

Ziel: keine Meta-Anweisungen, kein Doppel-Style, sparsames Negative-
Prompting, positives Framing.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


# Seedance-Mention-Tags (@Image1, @Video2, @Audio3 ...) — Modul-weit,
# weil sowohl `_strip_prompt_slop` (Mask-Unmask) als auch
# `build_for_seedance_2` (Subject-Pass-Through-Detection) sie brauchen.
_AT_TAG_RE = re.compile(r"@(?:Image|Video|Audio)\d+", re.IGNORECASE)


@dataclass
class PromptPayload:
    """Strukturierte Eingabe — Builder formuliert daraus den Provider-Prompt."""
    # WAS — Subject(s) + konkrete Pose
    subject: str
    """Konkrete Beschreibung der Person/Gruppe inkl. Pose UND Vektor.
    Beispiel: 'Alex, junge Lehrerin Mitte 30, kurze braune Haare, runde
    Brille, navy Strickjacke, steht im offenen Schultor, linkes Bein
    einen Schritt vor, Blick leicht nach unten, Tasche locker an der
    rechten Hand, im Begriff in den Hof zu gehen.'
    """

    # WO — Location-Detail
    setting: str = ""
    """Location-Beschreibung. Bei Sheet (clean studio): leer oder
    'seamless plain white studio backdrop'.
    """

    # WIE — Komposition + Camera (Position + Move)
    composition: str = ""
    """Distanz/Frame, Bildaufteilung. 'medium-wide shot, character
    slightly left of center'.
    """
    camera: str = ""
    """Kamera-Position UND Bewegung über die Shot-Dauer.
    'low-angle ~1.5 m camera, static for the first 2 s, then a slow
    1 m dolly-back as the character starts walking.'
    """

    # STIL — Look-Vokabular
    style: str = ""
    """Stil-Beschreibung 1:1 aus brief.visual_medium_notes / look.style.
    'Anime im Stil von Studio Ghibli / Makoto Shinkai — soft lighting,
    detailed backgrounds, cel-shaded figures.'
    """

    # LICHT
    light: str = ""
    """'warm morning light from the left, long soft shadow, calm.'"""

    # NEGATIVE — sparsam, nur Style-Excludes
    negatives: list[str] = field(default_factory=list)
    """Style-Excludes wie 'no text', 'no watermarks', 'no signature'.
    NICHT für Inhalts-Excludes ('no man in scene') — bei den meisten
    Modellen positive framing besser ('empty hallway').
    """

    # SHEET-spezifisch
    sheet_view: str = ""
    """'front' | 'side' | 'back' | 'expression_<tag>' | 'wide' |
    'alt_angle' | 'detail'. Wenn gesetzt → Sheet-Modus, sonst Frame-Modus.
    """

    # FRAME-spezifisch
    is_start_frame: bool = False
    """True bei keyframe_strategy=start/start_end für die Subject-Pose
    (t=0). Erzwingt Marker wie 'arrested mid-step' im Subject-Text,
    ohne Meta-Sprech wie 'THIS IS THE FIRST FRAME'.
    """

    # VIDEO-spezifisch (Seedance/Veo)
    duration_s: float | None = None
    aspect_ratio: str = ""  # "16:9", "9:16", "1:1", ...
    n_shots: int = 1

    # MULTI-REF-Hinweise — wenn mehrere Reference-Images übergeben
    # werden, kann jeder Pfad mit einem Klartext-Tag im Prompt
    # referenziert werden („Image 1: location entrance angle, Image 2:
    # wide courtyard reference"). Liste muss Reihenfolge des
    # Reference-Image-Arrays exakt entsprechen.
    multi_ref_hints: list[str] = field(default_factory=list)


# ----- Standard-Negative-Listen (Style-Excludes, kein Inhalts-Block) -----

# Feature 27 (v0.11.13): "Constraints" sind ab jetzt **positiv**
# formuliert. Image-/Videomodelle ignorieren "no/not/avoid"-Tokens
# oder aktivieren sie sogar — die Konstanten beschreiben den
# erwuenschten Zustand statt das Verbot. Die alten DEFAULT_*_NEGATIVES-
# Namen bleiben als Backward-Kompat-Alias bestehen, zeigen aber auf
# die positive Variante.
DEFAULT_FRAME_POSITIVES = (
    "clean untyped surfaces",
    "clean unmarked image",
    "clean unsigned image",
)
DEFAULT_SHEET_CHARACTER_POSITIVES = (
    "clean untyped surfaces",
    "clean unmarked image",
    "clean unsigned image",
)
DEFAULT_LOCATION_POSITIVES = (
    "empty environment, only architecture and props visible",
    "composition centered on the location itself",
    "clean untyped surfaces",
    "clean unmarked image",
)
DEFAULT_PROP_POSITIVES = (
    "empty environment, only the prop visible",
    "composition centered on the prop itself",
    "framing tight on the object so the holder stays out of frame",
    "clean untyped surfaces",
    "clean unmarked image",
)

# Backwards-Compat-Alias — Sheet-Generierung und Tests greifen noch
# auf die alten ..._NEGATIVES-Namen zu. DEFAULT_FRAME_NEGATIVES und
# SEEDANCE_CHARACTER_NEGATIVES sind unbenutzt — koennen spaeter weg.
DEFAULT_SHEET_CHARACTER_NEGATIVES = DEFAULT_SHEET_CHARACTER_POSITIVES
DEFAULT_LOCATION_NEGATIVES = DEFAULT_LOCATION_POSITIVES
DEFAULT_PROP_NEGATIVES = DEFAULT_PROP_POSITIVES


# ----- Sheet-View-Direktiven (positiv formuliert) ------------------------

_CHARACTER_VIEW_DIRECTION = {
    "front":
        "front view, full character visible from head to toe, neutral "
        "standing pose facing camera, seamless plain white studio backdrop, "
        "even diffuse studio lighting, full body framing.",
    "side":
        "strict 90 degree side profile of the same character, full body, "
        "neutral standing pose, seamless plain white studio backdrop, "
        "even diffuse studio lighting.",
    "back":
        "back view of the same character, full body, neutral standing "
        "pose, seamless plain white studio backdrop, even diffuse studio "
        "lighting.",
}


def _expression_direction(view: str) -> str:
    tag = view.removeprefix("expression_").replace("_", " ")
    return (
        f"front portrait of the same character with a {tag} facial "
        "expression, bust-up framing, seamless plain white studio "
        "backdrop, even diffuse studio lighting."
    )


_LOCATION_VIEW_DIRECTION = {
    "wide":
        "wide architectural reference of the empty location, capturing "
        "the defining structural elements (walls, windows, doors, "
        "fixtures, furniture in original position). Adult eye-level "
        "camera, slight wide-angle to capture the full space, even "
        "neutral lighting.",
    "alt_angle":
        "alternate angle of the same empty location from the opposite "
        "side or 90 degree rotation, showing different structural "
        "elements than a wide view. Adult eye-level camera, even "
        "neutral lighting.",
    "detail":
        "detail shot of a defining feature of the same empty location "
        "(characteristic window, door, fixture, decoration). Even "
        "neutral lighting.",
    "entrance":
        "reference shot of the location seen from outside, looking in "
        "through the entrance — gate / door / threshold visible in the "
        "foreground, the interior or far side of the location visible "
        "beyond. Even neutral lighting.",
    # DEPRECATED — Floorplan-Ansatz fehlgeschlagen empirisch.
    # Direktive bleibt für Backward-Kompatibilität, sollte aber durch
    # eine scene3d-Pipeline ersetzt werden.
    "floorplan":
        "DEPRECATED. Top-down schematic — image models cannot reliably "
        "interpret this as geometric ground-truth. Use the scene3d "
        "pipeline (Marble + Re-Style) instead.",
}


def _location_view_direction(view: str) -> str:
    """Free-form Location-View-Keys.

    - bekannte Keys (`wide`, `alt_angle`, `detail`, `entrance`) ziehen
      die kuratierte Direktive.
    - `<base>.<variant>` (z.B. `wide.morning`, `detail.chalkboard`)
      nimmt die Base-Direktive plus einen Variant-Hinweis.
    - alles andere bekommt eine generische Template-Direktive.

    Räumliche Disziplin („no people") sitzt zentral hier, damit die
    Sheet-Generierung keine `STRICT: NO PEOPLE`-Caps mehr in den Prompt
    setzt.
    """
    if view in _LOCATION_VIEW_DIRECTION:
        return _LOCATION_VIEW_DIRECTION[view]
    if "." in view:
        base, variant = view.split(".", 1)
        variant_clean = variant.replace("_", " ").strip()
        base_text = _LOCATION_VIEW_DIRECTION.get(base)
        if base_text:
            return f"{base_text} Variant: {variant_clean}."
        return (
            f"reference shot of the same empty location, focused on the "
            f"{base.replace('_', ' ')} ({variant_clean}) area, even "
            f"neutral lighting."
        )
    return (
        f"reference shot of the same empty location, focused on the "
        f"{view.replace('_', ' ')} area, even neutral lighting."
    )


_PROP_VIEW_DIRECTION = {
    "default":
        "isolated product/prop reference shot, the prop centered on a "
        "seamless plain white studio backdrop, neutral diffuse studio "
        "lighting, full object visible, the prop alone in the frame.",
    "closed":
        "the same prop in its closed/folded/sealed state, isolated on a "
        "seamless plain white studio backdrop, neutral diffuse lighting.",
    "open":
        "the same prop in its open/unfolded/active state, isolated on a "
        "seamless plain white studio backdrop, neutral diffuse lighting.",
    "worn":
        "the same prop in a worn/used/aged state showing realistic wear, "
        "isolated on a seamless plain white studio backdrop, neutral "
        "diffuse lighting.",
    "clean":
        "the same prop in pristine/new condition, isolated on a seamless "
        "plain white studio backdrop, neutral diffuse lighting.",
}


def _prop_view_direction(view: str) -> str:
    if view in _PROP_VIEW_DIRECTION:
        return _PROP_VIEW_DIRECTION[view]
    # free-form key — generic template, isolated on white
    return (
        f"prop reference shot showing the {view.replace('_', ' ')} state, "
        "isolated on a seamless plain white studio backdrop, neutral "
        "diffuse lighting."
    )


def _sheet_view_direction(view: str, kind: str) -> str:
    if kind == "location":
        return _location_view_direction(view)
    if kind == "prop":
        return _prop_view_direction(view)
    if view in _CHARACTER_VIEW_DIRECTION:
        return _CHARACTER_VIEW_DIRECTION[view]
    if view.startswith("expression_"):
        return _expression_direction(view)
    raise ValueError(f"unbekannter character/ensemble-view {view!r}")


# ----- Provider-Builder ---------------------------------------------------

def _join_clean(parts: list[str]) -> str:
    out = []
    for p in parts:
        p = (p or "").strip()
        if not p:
            continue
        # Ensure each part ends with a period for skimmability
        if p[-1] not in ".!?":
            p += "."
        out.append(p)
    return " ".join(out)


# ----- Universeller Slop-Strip (Image + Video) ----------------------------
#
# Slop ist nicht provider-spezifisch. Vague Adjektive, Meta-Anweisungen,
# numerierte Storyboard-Struktur — all das verschlechtert Image-Modelle
# (Nano Banana, GPT-Image-2, Imagen) genauso wie Video-Modelle (Seedance).

# Vague Praise + Hard-Block-Tokens (Apiyi, OpenAI-Cookbook).
_UNIVERSAL_SLOP_TOKENS: frozenset[str] = frozenset({
    # Vague Praise
    "cinematic", "epic", "stunning", "amazing", "breathtaking", "masterpiece",
    "beautiful", "gorgeous", "magnificent", "spectacular", "incredible",
    "awesome", "perfect", "ultra-detailed", "highly detailed",
    "award-winning", "professional", "high-quality", "best-quality",
    "8k", "4k",
    # Apiyi-Hard-Block (Seedance: Jitter; auch im Bild semantisch leer)
    "fast", "very fast", "super fast", "lightning fast",
})

# Meta-Anweisungen, die das Modell verwirren. Werden gesamt geloescht.
# Pattern matchen ganze Saetze.
_META_INSTRUCTION_PATTERNS: tuple[str, ...] = (
    # "THIS IS THE FIRST FRAME of a moving video shot."
    # "This is the FIRST frame of the action, not the middle or end."
    r"\bthis\s+is\s+(?:the\s+)?(?:first|start|beginning|opening)\s+frame[^.]*\.",
    # "It is NOT a static comic panel."
    r"\bit\s+is\s+not\s+(?:a\s+)?(?:static|still|comic|drawing)[^.]*\.",
    # "STRICT: NO PEOPLE / NO FIGURES"
    r"\bstrict[:\s]+no[^.]*\.",
    # "MUST be / MUST NOT be" Anweisungen am Satzanfang
    r"\b(?:please|try to|if possible|versuche|eventuell)[^.,]*[.,]",
    # "IMPORTANT:" / "NOTE:" / "REMEMBER:" als Prefix
    r"\b(?:important|note|remember|attention)[:\s]+[A-Z][^.]*\.",
)

# Technische Spezifika — kein Modell parst das zuverlaessig.
_TECH_LINGO_REPLACEMENTS: tuple[tuple[str, str], ...] = (
    (r"\b\d+\s*mm\b", "normal lens feel"),
    (r"\bf[/.]?\d+(?:\.\d+)?\b", "shallow depth of field"),
    (r"\biso\s*\d+\b", ""),
    (r"\b\d+\s*fps\b", ""),
    (r"\b\d+\s*°\b", ""),
)

# Numerierte Storyboard-Struktur — Modelle wollen Prosa, nicht
# „1. MOTIV/FRAME-ZERO: …  2. KOMPOSITION: …".
# Wir entfernen die nummerierte Label-Form und die ALL-CAPS-Label.
_NUMBERED_LABEL_RE = (
    # "1. MOTIV/FRAME-ZERO:" / "2. KOMPOSITION:" / "5. LICHT:"
    r"\b\d+\.\s*[A-Z][A-Z/\-_]+[A-Z]:\s*",
    # Standalone ALL-CAPS-Label am Satzanfang ohne Nummer
    r"(?:^|\.\s+)([A-Z]{4,}(?:[/\-_][A-Z]+)*:\s*)",
)


def _strip_prompt_slop(text: str) -> str:
    """Universeller Slop-Strip fuer Image- und Video-Prompts.

    1. Loescht Vague Praise (cinematic, epic, stunning, gorgeous, …)
    2. Loescht Meta-Anweisungen (THIS IS THE FIRST FRAME, STRICT: NO …)
    3. Ersetzt technisches Lingo (50mm -> 'normal lens feel')
    4. Flattent numerierte Storyboard-Struktur (1. MOTIV: -> heraus)
    5. Konvertiert haeufige Inline-Negatives in positives Framing
       (visual_prompt enthaelt oft 'no cars' / 'no people')

    **WICHTIG:** `@Image1`, `@Image2`, ... `@Video1`, `@Audio1` etc.
    sind Seedance-Reference-Mode-Mention-Tags und duerfen NIE gestrippt
    werden. Sie werden vor dem Strip extrahiert und nach dem Strip
    wieder eingefuegt, falls eine Heuristik sie versehentlich erwischt.
    Belege siehe fal.ai/models/bytedance/seedance-2.0/reference-to-video
    — der Filter bindet URLs ohne Tag an gar nichts.

    Idempotent. Sicher auf leerem String. Mehrfache Spaces / leading
    punctuation werden am Ende aufgeraeumt.
    """
    import re

    if not text:
        return text

    # Explizites Mask-Unmask der Seedance-Mention-Tags. Modul-konstante
    # `_AT_TAG_RE` oben.
    placeholders: list[str] = []

    def _mask(m):
        placeholders.append(m.group(0))
        return f"\x00ATTAG{len(placeholders) - 1}\x00"

    out = _AT_TAG_RE.sub(_mask, text)

    # 1. Meta-Anweisungen (zuerst, sie matchen ganze Saetze)
    for pat in _META_INSTRUCTION_PATTERNS:
        out = re.sub(pat, "", out, flags=re.IGNORECASE)

    # 2. Numerierte / All-Caps-Labels
    for pat in _NUMBERED_LABEL_RE:
        out = re.sub(pat, " ", out)

    # 3. Vague-Praise-Tokens (word-boundary, case-insensitive)
    for tok in _UNIVERSAL_SLOP_TOKENS:
        out = re.sub(rf"\b{re.escape(tok)}\b", "", out, flags=re.IGNORECASE)

    # 4. Technisches Lingo
    for pat, repl in _TECH_LINGO_REPLACEMENTS:
        out = re.sub(pat, repl, out, flags=re.IGNORECASE)

    # 5. Inline-Negatives -> Positiv (haeufige Faelle aus
    #    visual_prompt-Texten)
    # Die Replace-Werte sind komplett negationsfrei.
    inline_negative_table = {
        r"\bno\s+text\b": "clean untyped surfaces",
        r"\bno\s+watermarks?\b": "clean unmarked image",
        r"\bno\s+signatures?\b": "clean unsigned image",
        r"\bno\s+people\b": "empty environment, only architecture visible",
        r"\bno\s+figures?\b": "empty environment, only setting visible",
        r"\bno\s+humans?\b": "empty environment, only setting visible",
        r"\bno\s+cars?\b": "empty road surface",
        r"\bno\s+logos?\b": "unbranded surfaces",
    }
    for pat, repl in inline_negative_table.items():
        out = re.sub(pat, repl, out, flags=re.IGNORECASE)

    # 6. Aufraeumen: doppelte Spaces, leading Punctuation, trailing ", ."
    out = re.sub(r"\s{2,}", " ", out)
    out = re.sub(r"\s+([.,;:])", r"\1", out)  # " ." -> "."
    out = re.sub(r"([.,;:]){2,}", r"\1", out)  # ".." -> "."
    out = out.strip(" ,.;:")

    # Unmask: Platzhalter zurueck zu Original-Tags.
    if placeholders:
        # Sentence-Delete-Regexes (META_INSTRUCTION_PATTERNS mit `[^.]*`)
        # koennen Tag-Placeholder mitloeschen wenn der maskierte Tag in
        # einem geloeschten Satz stand. Wir tracken welche Indizes nach
        # dem Strip noch im Output sind und haengen die fehlenden
        # Original-Tags am Ende an, damit kein Tag verloren geht.
        present_indices = {
            int(m.group(1))
            for m in re.finditer(r"\x00ATTAG(\d+)\x00", out)
        }

        def _unmask(m):
            idx = int(m.group(1))
            return placeholders[idx]
        out = re.sub(r"\x00ATTAG(\d+)\x00", _unmask, out)

        missing = [
            placeholders[i] for i in range(len(placeholders))
            if i not in present_indices
        ]
        if missing:
            # Fehlende Tags am Ende ergaenzen — Tag-Erhaltung schlaegt
            # Stil. Der Builder fuegt sowieso eine 2nd-Tier-Mention-
            # Phrase mit allen Tags an; ein zusaetzlicher Tag-Block
            # hier ist Redundanz, aber sicherer als Verlust.
            tail = " ".join(missing)
            out = (out + " " + tail).strip() if out else tail

    return out


def _positive_phrasing(neg: str) -> str:
    """Wandelt 'no people' / 'avoid X' in *vollstaendig* positives Framing.

    Das Mapping liefert Phrasen OHNE Negationswoerter (no/not/avoid/
    without/kein/keine). Bild- und Videomodelle (Gemini/Nano-Banana,
    Seedance 2.0) verarbeiten Negativ-Prompting schlecht oder gar nicht
    — sie aktivieren das Token TROTZ der Verneinung. Konsequent positiv
    beschreibt, was sichtbar sein SOLL.

    Wenn keine Umformulierung bekannt ist, geben wir den Original-
    String zurueck — der Linter (`PROMPT_CONTAINS_NEGATION`) wird das
    aufgreifen.
    """
    neg_l = neg.lower().strip()
    table = {
        # Inhalts-Excludes — positiver, was DA sein soll
        "no people": "empty environment, only architecture and props visible",
        "no figures": "empty environment, only setting visible",
        "no humans": "empty environment, only setting visible",
        "no text": "clean untyped surfaces",
        "no watermarks": "clean unmarked image",
        "no signature": "clean unsigned image",
        "no hands": "framing tight on the object so the holder stays out of frame",
        "no cars": "empty road surface",
        "no logos": "unbranded surfaces",
        # Look-Defects
        "no cgi look": "photorealistic capture quality",
        "no smooth ai skin": "natural skin micro-texture preserved",
        "no artificial facial distortions": "anatomically correct facial features",
        # Motion-Defects (Seedance-Defaults)
        "no jitter": "smooth stable framing with consistent motion",
        "no temporal flicker": "consistent lighting and color across all frames",
        "no identity drift": "the character's design stays identical to the references throughout",
        "no bent limbs": "clean correct anatomy with naturally articulated limbs",
        "avoid jitter": "smooth stable framing with consistent motion",
        "avoid bent limbs": (
            "clean correct anatomy, naturally articulated limbs, "
            "exactly the right number of limbs"
        ),
        "avoid temporal flicker": "consistent lighting and color across all frames",
        "avoid identity drift": (
            "the character's design stays identical to the references throughout"
        ),
        # Schatten
        "no exaggerated cast shadows": (
            "each character casts a small short soft shadow pooled "
            "at their feet, background shadows stay subtle"
        ),
    }
    out = table.get(neg_l)
    if out is not None:
        return out
    # Fallback: noch nicht abgedecktes Negativ. Lass den Originalstring
    # durch — Linter wird ihn als PROMPT_CONTAINS_NEGATION melden.
    return neg


def build_for_nano_banana(payload: PromptPayload, *, sheet_kind: str = "character") -> str:
    """Gemini 3 Pro Image / 3.1 Flash Image (Nano Banana 2 / Pro).

    Folgt Google-Cloud-Guide (Mai 2026):
      Text-to-Image: [Subject] + [Action] + [Location/context] +
                     [Composition] + [Style]
      Multimodal:    [References indexed] + [Relationship] + [New scenario]

    Wichtig:
    - POSITIVES Framing (kein 'no cars' -> stattdessen 'empty street').
    - References INDEXIERT (Image 1: ..., Image 2: ...), nicht "; "-Liste.
    - Photography-Vokabular ('low angle', '50mm look', 'shallow DoF').
    - Literaler Text wird in Quotes umgesetzt (siehe Helper).

    Quelle: https://cloud.google.com/blog/products/ai-machine-learning/
            ultimate-prompting-guide-for-nano-banana
    """
    # Universeller Slop-Strip auf allen Subject/Setting/etc.-Feldern,
    # nicht nur fuer Seedance — Image-Modelle ziehen Slop genauso.
    subject = _strip_prompt_slop(payload.subject)
    setting = _strip_prompt_slop(payload.setting)
    composition = _strip_prompt_slop(payload.composition)
    camera = _strip_prompt_slop(payload.camera)
    light = _strip_prompt_slop(payload.light)
    style = _strip_prompt_slop(payload.style)

    parts: list[str] = []
    if payload.sheet_view:
        # Sheet-Modus: Subject + Action („reference sheet") + View-Direktive
        parts.append(
            f"{subject}, captured as a "
            f"{payload.sheet_view.replace('_', ' ')} reference sheet"
        )
        parts.append(_sheet_view_direction(payload.sheet_view, sheet_kind))
    else:
        # Frame-Modus — Subject vorne, dann Action, dann Location, Composition, Style
        parts.append(subject)
        if setting:
            parts.append(setting)
        if composition:
            parts.append(composition)
        if camera:
            parts.append(camera)
        if light:
            parts.append(light)
    # Doppelten Style-Tag vermeiden — wenn subject schon eine
    # Style-Phrase enthaelt (typisch bei Hand-geschriebenen Shotlists:
    # 'flat 2D Hanna-Barbera animation style' steht im visual_prompt),
    # wuerde 'Style: <look.style>' den Modell-Output spalten und Style-
    # Drift triggern. Heuristik: 'style' im Subject erkennen.
    style_already_in_subject = "style" in subject.lower()
    if style and not style_already_in_subject:
        parts.append(f"Style: {style}")
    # Multi-Ref: explizit indexiert (Google-Pattern). Plus eindeutige
    # Use-Anweisung am Ende — mit zwei harten Direktiven:
    #
    # 1. „Output ONE single full-frame image" — Triptychon-Sperre.
    #    Empirisch reproduzierbar bei Gemini 3 Pro Image, wenn
    #    >= 2 Refs UND Subject-Text mehrere Objekte aufzaehlt.
    # 2. Ref-Rolle explizit als „style + composition anchor", nicht
    #    „ground truth" — letzteres triggert bei Multi-Ref haeufig
    #    Composite/Collage-Output.
    if payload.multi_ref_hints:
        ref_lines = "; ".join(
            f"Image {i+1}: {hint.strip()}"
            for i, hint in enumerate(payload.multi_ref_hints)
        )
        parts.append(
            f"References — {ref_lines}. Use these as style and composition "
            "anchors: match the flat illustration style, palette, line "
            "treatment, camera angle, and figure-to-set scale of the "
            "references. Stay strictly within the architectural depth "
            "and perspective already shown in the references. Output "
            "ONE single full-frame image filling the entire frame "
            "edge-to-edge as one unified continuous picture."
        )
    # Negatives in POSITIVES Framing umwandeln (Google-Empfehlung).
    if payload.negatives:
        positives = [_positive_phrasing(n) for n in payload.negatives]
        # Deduplizieren (gleiche positive Phrase nur einmal)
        seen: set[str] = set()
        dedup = []
        for p in positives:
            if p.lower() not in seen:
                dedup.append(p)
                seen.add(p.lower())
        parts.append("Composition rules: " + ", ".join(dedup))
    return _join_clean(parts)


def build_for_gpt_image_2(payload: PromptPayload, *, sheet_kind: str = "character") -> str:
    """OpenAI gpt-image-2 (April 2026).

    Folgt dem OpenAI-Cookbook + fal.ai Prompting-Guide:
    5-Slot-Template (Scene / Subject / Important details / Use case /
    Constraints), gelabelte Segmente auf eigener Zeile.

    Wichtig laut Doku:
    - Strukturierte Slots statt Fliesstext (Reasoning-Modell).
    - „Important details" buendelt materials, textures, lighting, camera
      angle, lens feel, composition, mood (vorher 3 separate Slots).
    - Multi-Image: „Image 1: ... Image 2: ..." mit klarem Use-Hint
      (kein Raten ueber Reference-Rollen).
    - Vague-Praise vermeiden („stunning ultra-detailed cinematic 8K"
      ist Anti-Pattern — concrete details statt Adjektiv-Soup).

    Quellen:
      OpenAI Cookbook „GPT Image Models Prompting Guide" (2026-04)
      fal.ai „Prompting GPT Image 2" (2026-04)
    """
    # Slop-Strip auch hier (Cookbook nennt Vague-Praise als Anti-Pattern).
    subject = _strip_prompt_slop(payload.subject)
    setting = _strip_prompt_slop(payload.setting)
    composition = _strip_prompt_slop(payload.composition)
    camera = _strip_prompt_slop(payload.camera)
    light = _strip_prompt_slop(payload.light)
    style = _strip_prompt_slop(payload.style)

    lines: list[str] = []
    if payload.sheet_view:
        lines.append(f"Scene:\n{_sheet_view_direction(payload.sheet_view, sheet_kind)}")
        lines.append(f"Subject:\n{subject}")
    else:
        if setting:
            lines.append(f"Scene:\n{setting}")
        lines.append(f"Subject:\n{subject}")
        # Important details bundelt composition + camera + light + style
        # — Cookbook-Pattern.
        details: list[str] = []
        if composition:
            details.append(composition)
        if camera:
            details.append(camera)
        if light:
            details.append(light)
        # Style nur ergaenzen, wenn nicht schon im Subject — vermeidet
        # doppelten Style-Tag, der Style-Drift verursacht.
        if style and "style" not in subject.lower():
            details.append(f"Style: {style}")
        if details:
            lines.append("Important details:\n" + " ".join(details))
    # Use case macht dem Modell klar, was der Output sein soll.
    if payload.sheet_view:
        if sheet_kind == "character":
            use_case = "character reference sheet for downstream image-to-video"
        elif sheet_kind == "location":
            use_case = "location reference plate for downstream image-to-video"
        else:
            use_case = f"{sheet_kind} reference plate"
    else:
        use_case = (
            "video keyframe (t=0 anchor frame)"
            if payload.is_start_frame
            else "video keyframe (end-position anchor frame)"
        )
    lines.append(f"Use case:\n{use_case}")
    # Multi-Image-Refs: indexiert. Two-Column-Logic: was bleibt invariant.
    if payload.multi_ref_hints:
        ref_lines = "\n".join(
            f"Image {i+1}: {hint.strip()}"
            for i, hint in enumerate(payload.multi_ref_hints)
        )
        lines.append(
            "References:\n" + ref_lines + "\n"
            "Use these as style and composition anchors: match the "
            "illustration style, palette, line treatment, camera angle, "
            "figure-to-set scale, and architectural depth of the "
            "references. Preserve face identity, body proportions, "
            "outfit, brand colors, lighting setup, framing. Treat the "
            "references as style guides only; stay strictly within the "
            "architectural depth and perspective already shown there. "
            "Output ONE single full-frame image filling the entire frame "
            "edge-to-edge as one unified continuous picture."
        )
    # Constraints: positives Framing wo moeglich (Cookbook Rule 5).
    if payload.negatives:
        positives = [_positive_phrasing(n) for n in payload.negatives]
        seen: set[str] = set()
        dedup = []
        for p in positives:
            if p.lower() not in seen:
                dedup.append(p)
                seen.add(p.lower())
        lines.append("Constraints:\n" + ", ".join(dedup))
    return "\n\n".join(line for line in lines if line and line.strip())


def build_for_imagen(payload: PromptPayload, *, sheet_kind: str = "character") -> str:
    """Google Imagen 4 Ultra.

    Imagen liebt photographische Sprache und konkrete Lighting-Setups.
    Keine Reference-Image-Unterstützung (siehe Capabilities) — der
    Prompt muss alleine tragen.
    """
    subject = _strip_prompt_slop(payload.subject)
    setting = _strip_prompt_slop(payload.setting)
    composition = _strip_prompt_slop(payload.composition)
    camera = _strip_prompt_slop(payload.camera)
    light = _strip_prompt_slop(payload.light)
    style = _strip_prompt_slop(payload.style)

    parts: list[str] = []
    if payload.sheet_view:
        parts.append(_sheet_view_direction(payload.sheet_view, sheet_kind))
        parts.append(subject)
    else:
        parts.append(subject)
        if composition:
            parts.append(composition)
        if setting:
            parts.append(setting)
        if camera:
            parts.append(camera)
        if light:
            parts.append(light)
    # Doppel-Style nur, wenn nicht schon im Subject.
    if style and "style" not in subject.lower():
        parts.append(style)
    # payload.negatives wird positiv uebersetzt, nicht roh
    # durchgereicht — Imagen ignoriert oder verstaerkt Negationen sonst.
    if payload.negatives:
        parts.append(", ".join(_positive_phrasing(n) for n in payload.negatives))
    # Single-Image-Direktive auch fuer Imagen — Subjekt mit mehreren
    # aufgezaehlten Items (Saloon, General Store, Bank) kann Imagen zu
    # einer Multi-Panel-Komposition verleiten.
    if not payload.sheet_view:
        parts.append(
            "Output a single full-frame image filling the entire frame "
            "edge-to-edge as one unified continuous picture."
        )
    return _join_clean(parts)


def build_for_runway_image(payload: PromptPayload, *, sheet_kind: str = "character") -> str:
    """Runway gen4_image / Runway-proxy zu Gemini.

    Pragmatisch wie gpt-image-2 — Runway-Proxy folgt typischerweise
    Standard-Konventionen.
    """
    return build_for_gpt_image_2(payload, sheet_kind=sheet_kind)


SEEDANCE_STANDARD_VIDEO_POSITIVES: tuple[str, ...] = (
    "smooth stable framing with consistent motion",
    "clean correct anatomy, naturally articulated limbs, "
    "exactly the right number of limbs",
    "consistent lighting and color across all frames",
    "the character's design stays identical to the references throughout",
)
"""Die alten ..._NEGATIVES (avoid jitter, …) wurden 1:1 in positive
Formulierungen uebersetzt. Image-/Videomodelle verarbeiten Negativ-
Prompting schlecht — sie aktivieren das Token trotz Verneinung. Positiv
beschreibt den erwuenschten Zustand."""

# Backwards-Compat-Alias.
SEEDANCE_STANDARD_VIDEO_NEGATIVES = SEEDANCE_STANDARD_VIDEO_POSITIVES


SEEDANCE_CHARACTER_POSITIVES: tuple[str, ...] = (
    "the character's facial features remain identical to the references",
    "body proportions stay identical to the references",
)
"""Identity-Lock-Phrasen, positiv formuliert. Werden ergaenzt wenn der
Shot Characters enthaelt (payload.subject erwaehnt Person/Subject)."""



# Worter, die Seedance 2.0 nachweislich verschlechtern — werden aus
# dem Prompt entfernt bevor er gesendet wird.
# Quelle: Apiyi „Seedance 2.0 Official Prompt Guide" Pitfalls,
# Higgsfield Library, awesome-seedance-2-prompts.
SEEDANCE_SLOP_TOKENS: frozenset[str] = frozenset({
    # Vague Praise (verursacht Generic-Output)
    "epic", "stunning", "amazing", "breathtaking", "masterpiece",
    "beautiful", "gorgeous", "magnificent", "spectacular", "incredible",
    "awesome", "perfect", "ultra-detailed", "highly detailed",
    "award-winning",
    # "fast" — Apiyi: erzeugt nachweislich Jitter
    "fast", "very fast", "super fast", "lightning fast",
})


# Technische Spezifika, die Seedance ignoriert / Artefakte erzeugt.
SEEDANCE_TECHNICAL_LINGO_RE = (
    # mm-Brennweite, f-stop, ISO, fps
    r"\b\d+\s*mm\b",
    r"\bf[/.]?\d+(?:\.\d+)?\b",
    r"\biso\s*\d+\b",
    r"\b\d+\s*fps\b",
    r"\b\d+\s*°\b",  # Gradzahlen
)


def _strip_seedance_slop(text: str) -> str:
    """Backward-Compat-Wrapper. Delegiert an den universellen Strip —
    Slop ist nicht Seedance-spezifisch.
    """
    return _strip_prompt_slop(text)


# Wort-Grenzen verwenden, damit "comic relief"/"comic timing"
# (Schreibstil-Adjektive) oder "cel phone" nicht als Cartoon-Style
# detektiert werden.
_CARTOON_STYLE_PATTERN = re.compile(
    r"\b("
    r"cartoon|"
    # "cel" matchen NUR in Cartoon-Kontext ("cel phone" als Tippfehler
    # von "cell phone" sonst False-Positive)
    r"cel[\s-](?:animation|shaded|shading|style)|"
    r"flat[\s-]2d|2d[\s-]animation|"
    r"anime|hanna[\s-]barbera|ghibli|looney[\s-]tunes|"
    r"comic[\s-]book|"  # nicht "comic" alleine — False-Positive bei "comic relief"
    r"vector[\s-]style"
    r")\b",
    re.IGNORECASE,
)


def _cartoon_shadow_constraint(payload: "PromptPayload") -> str | None:
    """Schatten-Disziplin fuer flachen Cartoon-/Cel-Look.

    Befund (Wueste, Sonnenuntergang): die zwei Figuren werfen
    massstabslos riesige Schlagschatten. Bei flachem Cartoon-Look ist
    das ein klarer Stilbruch — gewollt sind kurze, weiche Schatten
    direkt an den Fuessen.

    Heuristik: wenn `payload.style` ODER `payload.subject` ein
    Cartoon-/Cel-/Flat-Style-Token (mit Wort-Grenze) enthaelt, gibt
    der Builder automatisch eine positive Constraint aus, die das
    Schatten-Verhalten klein haelt. Erhalten bleibt die Lighting-
    Stimmung aus `payload.light` (z.B. warmer Sonnenuntergang).

    Wort-Grenzen verhindern False-Positives bei Substring-Matches wie
    "comic relief", "cel phone".
    """
    text = f"{payload.style or ''} {payload.subject or ''}"
    if not _CARTOON_STYLE_PATTERN.search(text):
        return None
    return (
        "flat even cartoon lighting; each character casts only a small "
        "short soft shadow pooled at their feet; background shadows "
        "stay subtle and consistent with the flat cel style"
    )


def _seedance_pacing_block(
    duration_s: float | None,
    *,
    is_pacing_arm: bool,
) -> str | None:
    """Pacing-Choreografie-Block fuer Seedance.

    Seedance neigt dazu, unter-spezifizierte Aktion auf die Clip-Dauer
    zu strecken (Slow-Motion-Effekt). Gegenmittel: dem Modell explizit
    eine Idle-In → Aktion → Idle-Out-Choreografie geben.

    - Bei Shots, die ein Pacing-Sanity-Check als "slow_motion_risk"
      markiert hat (is_pacing_arm=True), liefert dieser Block die
      ausfuehrliche Idle-Bracketing-Anweisung. Damit hat das Modell
      eine klare Zeit-Aufteilung und muss die Aktion nicht dehnen.
    - Bei normal gepacedten Shots ≥5s liefern wir einen kurzen
      Default-Pacing-Hinweis (rein positiv formuliert).
    - Kurze Shots (<5s) bekommen keinen Pacing-Block — sie sind designt
      knapp und brauchen keine Bracketing-Choreografie.
    """
    if duration_s is None or duration_s <= 0:
        return None
    if duration_s < 5.0 and not is_pacing_arm:
        return None
    if is_pacing_arm:
        # Verbose Idle-Bracketing — verhindert dass das Modell die
        # eine vorhandene Aktion auf duration_s streckt. Ausschliesslich
        # positiv formuliert.
        return (
            f"Pace this ~{duration_s:.0f}s shot naturally. "
            "Open with ~1s of settled idle (subtle breathing, small "
            "weight shift), perform the described action at a natural "
            "lifelike tempo, then hold a relaxed idle pose until the end. "
            "Use the idle holds before and after as the time-fill so the "
            "action itself stays at natural lifelike speed throughout. "
            "Keep subtle living motion across the whole clip."
        )
    # Default-Disziplin — kurzer Hinweis statt vollem Bracketing.
    return "Natural lifelike tempo throughout, with subtle living motion across the whole clip."


@dataclass
class ReferenceTag:
    """Eine Reference fuer den fal-Seedance Reference-Mode.

    Repraesentiert ein hochgeladenes Reference-Asset zusammen mit dem
    Klartext-Hint, an dem der Builder den `@ImageN`-Mention-Tag im
    Prompt platziert. **Reihenfolge der Liste = Reihenfolge der
    `image_urls`-Liste an fal** (1-basiert, also Position 0 → `@Image1`,
    Position 1 → `@Image2`). Wenn die Reihenfolge driftet, bindet der
    Tag an die falsche Reference.

    Single Source of Truth: der Reference-Asset-Resolver liefert sowohl
    die Liste fuer Builder als auch die URL-Liste fuer den fal-Submit —
    beide gehen aus demselben strukturierten Record hervor.
    """

    role: str  # 'character' | 'location' | 'prop'
    bible_id: str  # z.B. 'ai_cat', 'main_street', 'desk'
    hint: str  # Klartext-Phrase, z.B. 'AI Cat', 'the empty main street'


def build_for_seedance_2(
    payload: PromptPayload,
    *,
    has_start_image: bool = False,
    has_end_image: bool = False,
    is_pacing_arm: bool = False,
    reference_tags: list[ReferenceTag] | None = None,
) -> str:
    """ByteDance Seedance 2.0 (ueber Runway, 2026-05-Stand).

    Folgt der offiziellen 6-Step-Formel:
      Subject + Action + Environment + Camera (ONE move) + Style+Lighting + Constraints
    60-100 Woerter Ziel.

    Wichtige Best-Practice-Patterns:
    - Bei image-to-video (has_start_image=True): Subject-Beschreibung
      KURZ halten — der Anker traegt die Identitaet. Fokus auf MOTION
      und CAMERA. Pflicht-Phrase „preserve composition and colors".
    - Bei start_end (has_end_image=True): @Image1/@Image2-Notation
      (Runway-Seedance unterstuetzt das fuer Multi-Asset-Mention).
    - Lighting > alles (Apiyi: hoechster Quality-Hebel).
    - ONE camera movement only (Sanity prueft das separat).
    - Slop-Tokens („epic, stunning, fast") + technisches Lingo
      („50mm, f/2.8, 24fps, ISO 800") werden HART entfernt bevor
      gesendet — sie erzeugen reproduzierbar schlechtere Outputs.

    Quellen:
      Apiyi „Seedance 2.0 Official Prompt Guide" (2026-05)
      Higgsfield „Seedance 2.0 Complete Prompting Guide"
      WaveSpeed „Character Consistency in Seedance 2.0"
      YouMind-OpenLab/awesome-seedance-2-prompts (curated 2000+)
    """
    duration = payload.duration_s or 5
    aspect = payload.aspect_ratio or "16:9"
    n = payload.n_shots if payload.n_shots > 0 else 1

    parts: list[str] = []

    # ===== Seedance-2 Reference-Mode =====
    # fal/Seedance-2.0 reference-to-video verlangt `@ImageN`-Mention-
    # Tags im Prompt, damit jede hochgeladene Reference an ihr Subjekt
    # bindet (siehe fal.ai/models/bytedance/seedance-2.0/
    # reference-to-video). Ohne Tags haengt die Identitaet faktisch nur
    # an der Textbeschreibung — Anker driften / werden unterbewertet.
    # Der i2v-Pfad weiter unten hat das schon laenger fuer Start/End-
    # Frames; der Reference-Pfad lief frueher als reiner t2v-Prompt
    # durch.
    #
    # Tag-Reihenfolge: 1-basiert, in EXAKT der Reihenfolge der
    # `image_urls`-Liste, die der Dispatcher an fal schickt. Same-order
    # ist die einzige Garantie, dass `@Image1` an die richtige Reference
    # bindet.
    if reference_tags:
        # Pflicht-Einleitung: jedes Asset wird mit @ImageN + Klartext
        # eingefuehrt, damit Seedance den Tag an den Bildinhalt bindet.
        intro_parts: list[str] = []
        for i, tag in enumerate(reference_tags, start=1):
            label = f"@Image{i}"
            if tag.role == "character":
                intro_parts.append(f"{label} is {tag.hint}.")
            elif tag.role == "location":
                intro_parts.append(f"{label} shows {tag.hint}.")
            elif tag.role == "prop":
                intro_parts.append(f"{label} is {tag.hint}.")
            else:
                intro_parts.append(f"{label}: {tag.hint}.")
        parts.append(" ".join(intro_parts))
        # Action — der Subject-Text aus dem Shot.
        #
        # Subject darf bereits @ImageN-Tags enthalten. Der Project-Agent
        # kennt die Bible-Resolver-Reihenfolge (character_refs →
        # location_ref → prop_refs) und schreibt die Tags beim Shotlist-
        # Schreiben direkt in den visual_prompt. Beispiel:
        #   Statt "Claude Mouse waves while AI Cat watches."
        #   schreibt der Agent "@Image2 waves while @Image1 watches."
        # Wenn der Subject-Text bereits Tags enthält, lassen wir ihn
        # as-is durch — kein künstliches @Image1-Prefix mehr. So
        # kontrolliert der Agent die Bindung, und die alte Heuristik
        # (erstes character-Tag) wird nur als Fallback genutzt.
        #
        # Ein Sanity-Check kann vor dem Render warnen wenn Bible-Char-
        # Namen im visual_prompt ohne entsprechende @-Tags auftauchen —
        # Disziplin am Schreibzeitpunkt, nicht erst hier.
        action_focus = _strip_seedance_slop(payload.subject)
        subject_already_tagged = bool(
            action_focus and _AT_TAG_RE.search(action_focus)
        )
        if subject_already_tagged:
            # Subject hat seine eigenen @ImageN-Bindungen — wir lassen
            # sie unverändert durch.
            parts.append(action_focus)
        else:
            # Backward-Kompat: Subject ohne Tags. Heuristik bindet den
            # ersten character-Tag an die Action.
            first_char_idx = next(
                (i for i, t in enumerate(reference_tags, start=1)
                 if t.role == "character"),
                None,
            )
            if action_focus:
                if first_char_idx is not None:
                    parts.append(f"@Image{first_char_idx} {action_focus}")
                else:
                    # Kein Character-Tag — Action steht ohne @-Bindung;
                    # die Tags sind Location/Prop und werden ueber Intro +
                    # 2nd-Tier-Mention referenziert.
                    parts.append(action_focus)
            elif first_char_idx is not None:
                parts.append(f"@Image{first_char_idx} in the framed action.")
            else:
                parts.append("The framed action plays out.")
        # Setting + Style: wenn der Brief explizit ein Setting / einen
        # Style-Override gesetzt hat, geht das auch in den Reference-
        # Mode mit rein. Sheets tragen den Stil primaer; ein Brief-
        # Style-Override (z.B. "wie Studio Ghibli") geht damit nicht
        # verloren.
        if payload.setting:
            parts.append(_strip_seedance_slop(payload.setting))
        if payload.camera:
            parts.append(_strip_seedance_slop(payload.camera))
        if payload.light:
            parts.append(_strip_seedance_slop(payload.light))
        if payload.style:
            parts.append(_strip_seedance_slop(payload.style))
        # 2nd-Tier-Mention fuer ALLE Tags: fal-Best-Practice verlangt
        # mind. 1 Vorkommen je Tag. Das Intro liefert das, aber zur
        # Sicherheit binden wir alle Tags nochmal an die Identity-
        # Preserve-Phrase. Damit hat jeder Tag mindestens 2
        # Erwaehnungen, was den Anchor stabiler macht.
        if len(reference_tags) > 1:
            joined = ", ".join(
                f"@Image{i + 1}" for i in range(len(reference_tags))
            )
            parts.append(
                f"{joined} stay on-model and visually consistent with their "
                "reference images throughout the shot."
            )
        # Pflicht-Phrase fuer Reference-Mode: Identitaet kommt aus den
        # Refs, nicht aus dem Text.
        parts.append(
            "Preserve identity, design, colors, and proportions "
            "from the referenced images throughout the shot."
        )
    elif has_start_image or has_end_image:
        # Image-to-video Modus — kompakter Prompt, Image traegt die Identitaet.
        # Apiyi/Higgsfield: 30-60 Woerter genug, MUSS Anker-Direktive enthalten.
        if has_start_image and has_end_image:
            parts.append("@Image1 is the first frame at t=0, @Image2 is the final frame at t=duration.")
        elif has_start_image:
            parts.append("@Image1 is the first frame at t=0.")
        # Action (was passiert vom Start-Frame aus) — KURZ
        # Subject-Identitaet steht im Image, hier nur Aktion + Camera + Light.
        action_focus = _strip_seedance_slop(payload.subject)
        if action_focus:
            parts.append(action_focus)
        if payload.camera:
            parts.append(_strip_seedance_slop(payload.camera))
        if payload.light:
            parts.append(_strip_seedance_slop(payload.light))
        # Pflicht-Phrase fuer image-to-video (Higgsfield-Guide)
        parts.append("Preserve composition, colors, identity, and lighting from the anchor frame(s).")
    else:
        # text-to-video Modus — voller 6-Step
        # Step 1 — Subject
        parts.append(_strip_seedance_slop(payload.subject))
        # Step 2 — Action steckt typischerweise schon im Subject; Composition als Aktions-Marker
        if payload.composition:
            parts.append(_strip_seedance_slop(payload.composition))
        # Step 3 — Environment
        if payload.setting:
            parts.append(_strip_seedance_slop(payload.setting))
        # Step 4 — Camera (Sanity prueft: genau eine Bewegungsart)
        if payload.camera:
            parts.append(_strip_seedance_slop(payload.camera))
        # Step 5 — Style + Lighting (Lighting hat hoechsten Hebel)
        if payload.light:
            parts.append(_strip_seedance_slop(payload.light))
        if payload.style:
            parts.append(_strip_seedance_slop(payload.style))

    # Step 6 — Constraints (positiv). Vorher gab es einen "Avoid: …"-
    # Block — Seedance ignoriert Negativ-Prompting oder aktiviert das
    # Token sogar. Jetzt ausschliesslich positive Beschreibungen des
    # erwuenschten Zustands.
    user_constraints = [_positive_phrasing(n) for n in (payload.negatives or [])]
    standard_constraints = list(SEEDANCE_STANDARD_VIDEO_POSITIVES)
    subject_lower = payload.subject.lower()
    has_character = any(
        token in subject_lower
        for token in ("person", "character", "man", "woman", "girl", "boy",
                      "performer", "musician", "singer", "dancer", "child",
                      "adult", "teen", "people", "figure")
    )
    if has_character:
        standard_constraints.extend(SEEDANCE_CHARACTER_POSITIVES)
    # Schatten-Disziplin bei flachem/Cartoon-Look automatisch ergaenzen.
    shadow_constraint = _cartoon_shadow_constraint(payload)
    if shadow_constraint:
        standard_constraints.append(shadow_constraint)
    all_constraints = user_constraints + [
        c for c in standard_constraints if c not in user_constraints
    ]
    if all_constraints:
        parts.append("Constraints: " + "; ".join(all_constraints) + ".")

    # Pacing-Block: explizite Zeit-Choreografie, damit Seedance nicht
    # streckt. Default-Disziplin fuer Shots ≥5s, Idle-Bracketing-
    # Variante fuer pacing-arme Shots.
    pacing_block = _seedance_pacing_block(
        payload.duration_s, is_pacing_arm=is_pacing_arm,
    )
    if pacing_block:
        parts.append(pacing_block)

    # Structure-Tail (Runway-spec, kurz halten). "no cuts" →
    # "one continuous take" — positiv formuliert.
    if reference_tags or has_start_image or has_end_image:
        parts.append(f"Total: {duration:.0f}s, {aspect}.")
    else:
        header_kind = (
            "Single continuous shot as one continuous take" if n == 1
            else f"{n}-shot sequence as one continuous take"
        )
        parts.append(
            f"{header_kind}. Total: {duration:.0f}s / {aspect}."
        )
    return _join_clean(parts)


# ----- Dispatcher ---------------------------------------------------------

def build_image_prompt(
    model_id: str,
    payload: PromptPayload,
    *,
    sheet_kind: str = "character",
) -> str:
    """Wählt den richtigen Builder anhand des `<provider>:<model>`-Namespaces."""
    provider = model_id.split(":", 1)[0] if ":" in model_id else model_id
    model = model_id.split(":", 1)[1] if ":" in model_id else ""
    if provider == "google":
        if "imagen" in model.lower():
            return build_for_imagen(payload, sheet_kind=sheet_kind)
        return build_for_nano_banana(payload, sheet_kind=sheet_kind)
    if provider == "openai":
        return build_for_gpt_image_2(payload, sheet_kind=sheet_kind)
    if provider == "runway":
        return build_for_runway_image(payload, sheet_kind=sheet_kind)
    # Fallback: gpt-image-2-Format ist robust
    return build_for_gpt_image_2(payload, sheet_kind=sheet_kind)


def build_video_prompt(
    model_id: str,
    payload: PromptPayload,
    *,
    has_start_image: bool = False,
    has_end_image: bool = False,
    is_pacing_arm: bool = False,
    reference_tags: list[ReferenceTag] | None = None,
) -> str:
    """Aktuell mappen alle Video-Modelle auf Seedance-Format. Veo/Gen4
    bekommen denselben Header — sie tolerieren das, profitieren aber von
    weniger Camera-Verboten als Seedance.

    `has_start_image` / `has_end_image` aktivieren im Seedance-Builder
    den image-to-video-Pfad (kompakte Form, @Image1/@Image2-Notation,
    Pflicht-Phrase 'Preserve composition, colors, identity, and
    lighting from the anchor frame(s).').

    `reference_tags` aktiviert den Reference-Mode-Pfad: pro hochgeladenes
    Bible-Asset ein `@ImageN`-Mention-Tag im Prompt, in genau der
    Reihenfolge der `image_urls`-Liste an fal. Caller (Dispatcher) muss
    die Tags und URLs aus DERSELBEN Quelle ziehen, sonst bindet der Tag
    an die falsche Reference.

    `is_pacing_arm` aktiviert die ausfuehrliche Idle-Bracketing-
    Choreografie statt der Default-Pacing-Disziplin. Der Dispatcher
    setzt das anhand einer Pacing-Heuristik — bei `slow_motion_risk`
    greift Idle-Bracketing.
    """
    return build_for_seedance_2(
        payload,
        has_start_image=has_start_image,
        has_end_image=has_end_image,
        is_pacing_arm=is_pacing_arm,
        reference_tags=reference_tags,
    )
