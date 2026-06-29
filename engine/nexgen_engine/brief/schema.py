"""Brief (K1): Ergebnis der Konzeptionsphasen-Eröffnung.

Sammelt die 7 Kernfragen, die jeder Konzeption vorausgehen MUSS, bevor
der treatment-agent loslegen darf. Persistiert als projects/<name>/brief.yaml.

Die Fragen werden vom brief-agent über AskUserQuestion gestellt, die
Antworten hier abgelegt und vom Gate `brief` freigegeben.
"""

from __future__ import annotations

from enum import Enum
from pathlib import Path
from typing import Annotated

import yaml
from pydantic import BaseModel, ConfigDict, Field, model_validator

BRIEF_SCHEMA_VERSION = "brief/v1"


class Mission(str, Enum):
    SINGLE_RELEASE = "single_release"
    SOCIAL_POST = "social_post"
    ART_PIECE = "art_piece"
    DEMO = "demo"
    OTHER = "other"


class AspectRatio(str, Enum):
    LANDSCAPE_16_9 = "16:9"
    VERTICAL_9_16 = "9:16"
    SQUARE_1_1 = "1:1"
    PORTRAIT_4_5 = "4:5"
    LANDSCAPE_5_4 = "5:4"
    LANDSCAPE_4_3 = "4:3"
    PORTRAIT_3_4 = "3:4"
    LANDSCAPE_21_9 = "21:9"
    VERTICAL_9_21 = "9:21"
    OTHER = "other"


class ConceptType(str, Enum):
    NARRATIVE = "narrative"
    PERFORMANCE = "performance"
    ABSTRACT = "abstract"
    DOCUMENTARY = "documentary"
    HYBRID = "hybrid"
    OTHER = "other"


class FigurePresence(str, Enum):
    ARTIST_ONLY = "artist_only"
    ARTIST_PLUS_OTHERS = "artist_plus_others"
    OTHERS_ONLY = "others_only"
    NONE = "none"
    OTHER = "other"


class LyricsIntegration(str, Enum):
    LITERAL = "literal"
    METAPHORICAL = "metaphorical"
    CONTRASTIVE = "contrastive"
    IGNORED = "ignored"
    OTHER = "other"


class ModelPreference(str, Enum):
    GEN3A_TURBO = "gen3a_turbo"
    GEN4_5 = "gen4.5"
    SEEDANCE2 = "seedance2"
    VEO3 = "veo3"
    VEO3_1_FAST = "veo3.1_fast"
    PER_SHOT = "per_shot"
    OTHER = "other"


class FrameImageModel(str, Enum):
    """Image-Modell für Phase F (Standbilder) und K5 (Bible-Images).

    Namespaced: `<provider>:<internal_model>` damit verschiedene Zugänge
    zum selben Modell unterscheidbar sind (z.B. Google direkt vs. Runway-Proxy).
    Der tatsächliche Provider wird durch `musicvideo.render.images.registry`
    bestimmt.
    """
    # Google direct (Premium, empfohlen für narrative Videos)
    GOOGLE_GEMINI_3_PRO = "google:gemini-3-pro-image-preview"                       # Nano Banana Pro
    GOOGLE_GEMINI_3_1_FLASH = "google:gemini-3.1-flash-image-preview"       # Nano Banana 2
    GOOGLE_IMAGEN_4_ULTRA = "google:imagen-4.0-ultra-generate-001"          # Imagen 4 Ultra
    # OpenAI direct
    OPENAI_GPT_IMAGE_2 = "openai:gpt-image-2"                               # ChatGPT Images 2.0 (Org-Verifizierung nötig)
    OPENAI_GPT_IMAGE_1 = "openai:gpt-image-1"                               # Vorgänger, sofort nutzbar
    # Runway (Proxy / eigenes Modell)
    RUNWAY_GEMINI_3_PRO = "runway:gemini_image3_pro"
    RUNWAY_GEMINI_3_1_FLASH = "runway:gemini_image3.1_flash"
    RUNWAY_GEMINI_2_5_FLASH = "runway:gemini_2.5_flash"
    RUNWAY_GEN4_IMAGE = "runway:gen4_image"
    RUNWAY_GEN4_IMAGE_TURBO = "runway:gen4_image_turbo"
    # fal.ai (v0.11.0, optional Stufe-b)
    FAL_NANO_BANANA = "fal:fal-ai/nano-banana"
    FAL_IMAGEN_4_ULTRA = "fal:fal-ai/imagen4/preview/ultra"
    FAL_GPT_IMAGE_1 = "fal:fal-ai/gpt-image-1"
    FAL_FLUX_PRO_1_1 = "fal:fal-ai/flux-pro/v1.1"
    OTHER = "other"


class StemsProvider(str, Enum):
    """Wer macht die Stem-Separation."""
    NONE = "none"
    DEMUCS = "demucs"      # lokal, kostenlos, gut
    LALAL = "lalal"        # LALAL.AI API, pay-per-song, premium


class VisualMedium(str, Enum):
    """Visuelles Medium / Rendering-Register.

    Entscheidet über den Grundcharakter der Bilder — live-action-Film,
    3D-CG, 2D-Animation usw. Prägt Frame-Image-Modell-Wahl, Runway-Modell,
    Bible-Look-Defaults und Shotlist-Prompt-Sprache.

    Pflichtfeld, kein Default. Bestehende brief.yaml ohne das Feld failen
    bei load() — das ist Absicht, damit der Revision-Loop die Frage stellt.
    """
    LIVE_ACTION_REALISTIC = "live_action_realistic"      # realistischer Film-Look
    LIVE_ACTION_STYLIZED = "live_action_stylized"        # real, stark gegradet/stilisiert
    CG_3D = "3d_cg"                                      # CG, photoreal oder stylized
    ANIMATION_2D = "2d_animation"                        # Trickfilm, Anime, Cel-Shading
    ILLUSTRATION = "illustration"                        # gemalt, Comic, Aquarell
    STOP_MOTION = "stop_motion"                          # Claymation, Puppentrick
    MIXED = "mixed"                                      # Shot-für-Shot unterschiedlich
    OTHER = "other"


class VideoResolution(str, Enum):
    """Render-Resolution fuer den finalen Pass (v0.11.7).

    Vom Brief-Agent zur Brief-Zeit abgefragt. Defaults sind dokumentiert
    in `.claude/phases/brief.md`. Pflicht-Feld, kein Default — der
    Brief-Agent stellt die Frage explizit.

    Fal-Modell-Mapping:
    - `RES_720P` → Pro oder Fast moeglich.
    - `RES_1080P` → nur Pro (Fast hat kein 1080p, fal-Modell-Limit).
    """
    RES_720P = "720p"
    RES_1080P = "1080p"


class PreviewMode(str, Enum):
    """Preview-Render-Strategie (v0.11.7).

    Pflicht-Feld im Brief, kein Default. Hintergrund-Berechnung:
    Preview ist ein **zusaetzlicher** Render-Pass — kein Rabatt
    gegenueber Direkt-Final. Sinn nur, wenn die Risiko-Minderung
    den Aufpreis schlaegt.

    - SKIP: kein Preview-Pass. Direkt Final-Render. Pilotierung
      ueber `mv-render final --only s001,s004`.
    - SMALLEST: Preview auf kleinstem verfuegbaren fal-Tier
      (`fal:bytedance/seedance-2.0/fast` @ 720p — 480p ist auf fal
      nicht eindeutig gepreist, daher nicht angeboten).
    """
    SKIP = "skip"
    SMALLEST = "smallest"


class CutHandlesMode(str, Enum):
    """Schnitt-Handles-Strategie nach Render (v0.12.1).

    Seedance/Runway-Renders kommen seit Bug 28 (v0.11.11) IMMER mit der
    Kern-Dauer (`shot.duration_s`) — keine handle-gepaddete Aktion
    mehr. Was nach dem Provider-Render passiert, entscheidet dieser
    Mode:

    - WITH_OVERLAP: `mv-render handles` haengt deterministische
      Pre-/Post-Freeze-Frames an (ffmpeg tpad, Default-Padding aus
      `costs.yaml::overlap.pre_s/post_s`). Output in
      `renders/<phase>s_handles/`, Originale unangetastet. Empfohlen
      fuer manuellen FCP-/DaVinci-Schnitt mit J-Cut/L-Cut-Toleranz
      und Crossfades.
    - BACK_TO_BACK: kein Handle-Anhang, Renders bleiben exakt
      `shot.duration_s`. Empfohlen fuer harten Back-to-Back-Edit
      direkt aus den Renders, wo der Schnitt schon im Storyboard
      kalkuliert ist und kein Editor-Spielraum benoetigt wird.

    Pflichtfrage fuer NEUE Briefs — der Brief-Agent fragt den
    Schnitt-Workflow ab und persistiert die Wahl. Der Schema-Default
    `WITH_OVERLAP` existiert ausschliesslich aus Backward-Kompat-
    Gruenden: brief.yaml-Dateien aus v0.12.0 oder aelter, die das
    Feld nicht enthalten, laden mit dem bisherigen Verhalten weiter.
    Neue Briefs sollen die Antwort explizit setzen — Skill-Agent
    darf den Default nicht ratend uebernehmen.
    """
    WITH_OVERLAP = "with_overlap"
    BACK_TO_BACK = "back_to_back"


class ToneTag(str, Enum):
    MELANCHOLIC = "melancholic"
    IRONIC = "ironic"
    EUPHORIC = "euphoric"
    DARK = "dark"
    SURREAL = "surreal"
    POETIC = "poetic"
    ENERGETIC = "energetic"
    QUIET = "quiet"
    OTHER = "other"


class Brief(BaseModel):
    """Pflicht-Input des Regisseurs vor dem Treatment."""

    model_config = ConfigDict(extra="forbid")

    schema_: str = Field(alias="schema", default=BRIEF_SCHEMA_VERSION)
    project: str
    generated: str
    generator: str = "brief-agent@v0.3"

    # Frage 1 — Mission / Plattform
    mission: Mission
    mission_other: str | None = None
    target_platform: str  # Freitext, weil zu viele Kombinationen
    target_audience: str | None = None

    # Frage 2 — Format
    aspect_ratio: AspectRatio
    aspect_ratio_other: str | None = None
    length_mode: str = "full_song"  # "full_song" oder Freitext "0:00-1:30"

    # Frage 3 — Technik
    project_mode: str  # beat | phrase | section | multicam (matches shotlist.Mode)
    model_preference: ModelPreference = ModelPreference.SEEDANCE2
    model_preference_other: str | None = None
    frame_image_model: FrameImageModel = FrameImageModel.GOOGLE_GEMINI_3_PRO
    """Default-Modell. Legacy single-slot; bleibt für Rückwärtskompatibilität.
    Wenn `bible_image_model` und `composite_image_model` nicht gesetzt sind,
    nimmt der Builder beide aus diesem Feld."""
    frame_image_model_other: str | None = None

    bible_image_model: FrameImageModel | None = None
    """Spezialisiertes Modell für Bible-Sheets (Character/Ensemble/Location/
    Prop). Empfohlen: Nano Banana Pro (`google:gemini-3-pro-image-preview`)
    wegen Multi-Reference-Konsistenz und Portrait-Qualität (Mai-2026-
    Benchmarks). None = Fallback auf `frame_image_model`."""

    composite_image_model: FrameImageModel | None = None
    """Spezialisiertes Modell für Shot-Composites (komplexe Multi-Subject-
    Frames, Layout-getriebene Storyboards, Text-in-Bild). Empfohlen:
    GPT Image 2 (`openai:gpt-image-2`) wegen Reasoning, Layout-Planung und
    Text-Rendering. None = Fallback auf `frame_image_model`."""

    budget_eur: Annotated[float, Field(gt=0)] = 50.0

    # Frage 4 — Konzept-Typ
    concept_type: ConceptType
    concept_type_other: str | None = None

    # Frage 4a — Visuelles Medium / Rendering-Register (Pflicht, kein Default)
    visual_medium: VisualMedium
    visual_medium_other: str | None = None
    visual_medium_notes: str | None = None
    """Freitext-Präzisierung, z.B. 'wie Ghibli', 'wie Laika', 'Adult Swim'."""

    # Frage 5 — Ton & Stil
    tone: list[ToneTag] = Field(default_factory=list)
    tone_other: str | None = None
    style_references: list[str] = Field(default_factory=list)
    """Freitext-Referenzen (Videos, Filme, Regisseure, Bildsprachen)."""

    # Frage 6 — Figuren
    figures: FigurePresence
    figures_other: str | None = None
    figure_count_hint: str | None = None

    # Frage 7 — Lyrics-Integration
    lyrics_integration: LyricsIntegration
    lyrics_integration_other: str | None = None

    # Frage 8 — Chord-Analyse
    enable_chord_analysis: bool = False

    # Frage 9 — Stem-Separation-Provider
    stems_provider: StemsProvider = StemsProvider.DEMUCS

    # Frage 10 — Final-Resolution (v0.11.7, Pflicht)
    final_resolution: VideoResolution = VideoResolution.RES_1080P
    """Resolution fuer den finalen Render-Pass.

    Default 1080p — User-Memory `feedback_render_resolution_default.md`:
    'Render-Aufloesung Default 1080p+, 720p nur Ausnahme'. 720p ist
    bewusste Wahl wenn Budget knapp oder Final-Distribution
    explizit fuer 720p (z.B. Mobile-only Reels).

    fal-Modell-Mapping: 1080p → Pro (`fal:bytedance/seedance-2.0`,
    $0.682/s), 720p → Pro 720p ($0.3024/s) oder Fast 720p ($0.2419/s).
    Pricing-Quellen siehe costs.yaml Header."""

    # Frage 11 — Preview-Pass (v0.11.7, Pflicht)
    preview_mode: PreviewMode = PreviewMode.SKIP
    """Preview-Render-Strategie. Default SKIP — Preview ist ein
    *zusaetzlicher* Render-Pass und kein Rabatt gegenueber Direkt-
    Final-Render. Sinnvoll nur, wenn die Risiko-Minderung den
    Aufpreis schlaegt.

    Brief-Agent darf eine fakten-begruendete Empfehlung geben (siehe
    `musicvideo.brief.preview_recommendation`) — basierend auf:
    - Shot-Anzahl (kleine Projekte: SKIP, Pilotierung via --only)
    - Final-Estimate vs Budget (>40% → Risiko-Minderung lohnt)
    - Re-Render-Historie aus projects/<name>/renders/manifest-*.json
    - Brand-new vs etabliertes Projekt
    Empfehlung MUSS im Brief mit Begruendung notiert werden."""

    # Frage 12 — Cut-Handles-Mode (v0.12.1, Pflicht)
    cut_handles_mode: CutHandlesMode = CutHandlesMode.WITH_OVERLAP
    """Pre-/Post-Handle-Strategie nach Render. WITH_OVERLAP (Default,
    bisheriges Verhalten) haengt deterministische Standbild-Padding
    via `mv-render handles`. BACK_TO_BACK ueberspringt den Handle-
    Schritt — Renders bleiben exakt `shot.duration_s` und werden so
    in den Schnitt-Workflow uebernommen.

    Backward-Kompat: Default WITH_OVERLAP bedeutet, dass Briefs vor
    v0.12.1 das bisherige Verhalten behalten (Handles werden
    erzeugt). Wer harten Back-to-Back will, setzt explizit
    BACK_TO_BACK."""

    # Frage 13 — Director-Pattern (v0.12.0, optional)
    director_pattern: str | None = None

    # Genre-Cross-Escape (v0.13.0)
    allow_genre_cross_patterns: bool = False
    """Erlaubt Pattern-Vorschlaege mit nicht-passendem visual_medium
    (sonst Hartes-Veto -10 Punkte). Default False — Skill schlaegt
    nur Pattern vor, deren visual_mediums-Trigger das Brief-Medium
    enthaelt. Auf True setzen, wenn bewusst Genre-Cross gewuenscht
    ist (Anime-Sprache auf live-action-Brief, Stop-Motion-Pacing
    auf 3D-CG-Brief, etc.). Die Score-Strafe reduziert sich dann
    auf -2 (vergleichbar mit mood-Mismatch)."""
    """Pattern-ID aus `musicvideo/patterns/library/` — User waehlt am
    Brief-Ende aus einem 2-3-Vorschlag, der aus `visual_medium`,
    `tone_tags`/Mood-Heuristik, BPM und `concept_type` abgeleitet
    wird. Optional: leer = Skill arbeitet ohne explizites Pattern-
    Backbone, aber dann greift im Storyboard auch der PATTERN_DRIFT-
    Sanity-Check nicht.

    Brief-Agent zeigt dem User pro Vorschlag Name + Description + die
    Referenzen mit Quellen. Auswahl wird hier persistiert. Beispiel:
    `narrative-folk-static-long-takes`."""

    # Stilistik-Constraint
    allow_text_overlays: bool = False
    """Erlaubt Title Cards / Schrifteinblendungen / Lower-Thirds in der
    Shotlist. Default False — Image-/Video-Modelle rendern Text schlecht,
    mehrfache Title Cards verstärken den Slop-Effekt. Sanity warnt
    standardmäßig bei Title-Card-Markern; mit `true` werden diese Warns
    unterdrückt (bewusste Designentscheidung für Stilmittel wie Doku/
    Newsreel/Karaoke-Look)."""

    notes: str | None = None

    @model_validator(mode="after")
    def _visual_medium_notes_required_for_stylized(self) -> "Brief":
        """Für alles außer live_action_realistic ist `visual_medium_notes` Pflicht.

        Begründung: Bei realistischem Film-Look reichen generische
        Kinematografie-Begriffe. Bei allen anderen Medien (2D-Anime vs
        Adult-Swim vs Ghibli, CG-Pixar vs CG-Arcane, Stop-Motion-Laika
        vs Aardman usw.) muss der Brief den konkreten Stil festlegen —
        sonst erfindet der Treatment-Agent eine generische Variante, die
        am User-Intent vorbeigeht.
        """
        needs_notes = {
            VisualMedium.LIVE_ACTION_STYLIZED,
            VisualMedium.CG_3D,
            VisualMedium.ANIMATION_2D,
            VisualMedium.ILLUSTRATION,
            VisualMedium.STOP_MOTION,
            VisualMedium.MIXED,
            VisualMedium.OTHER,
        }
        if self.visual_medium in needs_notes:
            if not self.visual_medium_notes or not self.visual_medium_notes.strip():
                raise ValueError(
                    f"visual_medium={self.visual_medium.value} erfordert "
                    f"visual_medium_notes (konkreter Stil, z.B. 'wie Ghibli', "
                    f"'wie Pixar Arcane', 'wie Laika'). Leer oder fehlend nicht zulässig."
                )
        return self


def load(project_dir: Path) -> Brief:
    path = project_dir / "brief.yaml"
    if not path.exists():
        raise FileNotFoundError(f"{path} fehlt — brief-agent (K1) aufrufen")
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    return Brief.model_validate(data)


def save(project_dir: Path, brief: Brief) -> Path:
    path = project_dir / "brief.yaml"
    path.write_text(
        yaml.safe_dump(
            brief.model_dump(by_alias=True, exclude_none=True, mode="json"),
            sort_keys=False,
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    return path
