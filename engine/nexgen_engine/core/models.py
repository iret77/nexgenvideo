"""Video-Modell-Capabilities-Registry (Runway + fal, ab v0.11).

Wird vom sanity-agent und vom asset-/shotlist-agent genutzt, um
Projekt-Entscheidungen gegen Modell-Grenzen zu validieren.

Werte sind konservative Schätzungen — vor jedem großen Render gegen
die Provider-Pricing + API-Doc gegenchecken und hier pflegen.

Modell-IDs sind seit v0.11.0 provider-prefixed (`fal:...`/`runway:...`)
um Kollisionen zwischen gleichnamigen Modellen auf verschiedenen
Providern zu vermeiden (z.B. Runway-`seedance2` vs fal-Seedance-2).
Legacy-IDs ohne Präfix bleiben als Aliase erhalten für Altprojekte.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ModelCapability:
    max_duration_s: float
    supported_ratios: tuple[str, ...]
    max_characters_in_frame: int  # realistisch sauber haltbar
    supports_keyframe_start: bool
    supports_keyframe_end: bool
    supports_image_to_video: bool
    supports_reference_mode: bool = False
    """Multi-Image-Refs per @image1-Mention (Seedance 2 Native Feature,
    auf Runway NICHT exposed). Wenn True, akzeptiert das Modell bis zu
    9 Bilder + 3 Videos + 3 Audio als Refs.
    """
    max_reference_images: int = 0
    notes: str = ""


MODEL_CAPABILITIES: dict[str, ModelCapability] = {
    "gen3a_turbo": ModelCapability(
        max_duration_s=10.0,
        supported_ratios=("1280:720", "720:1280", "960:960", "1104:832", "832:1104"),
        max_characters_in_frame=2,
        supports_keyframe_start=True,
        supports_keyframe_end=False,
        supports_image_to_video=True,
        notes="Günstig, schnell. Gut für Previews. Limits bei komplexen Szenen.",
    ),
    "gen4.5": ModelCapability(
        max_duration_s=10.0,
        supported_ratios=("1280:720", "720:1280", "960:960", "1104:832", "832:1104"),
        max_characters_in_frame=3,
        supports_keyframe_start=True,
        supports_keyframe_end=True,
        supports_image_to_video=True,
        notes="Beste Charakter-Konsistenz, bevorzugt bei Narrativ+Performance.",
    ),
    "seedance2": ModelCapability(
        max_duration_s=15.0,
        # ECHTE Liste aus der Runway-API (Live-400-Response, 2026-05-31).
        # Vorherige Liste war zum grossen Teil fiktiv (1280:960, 960:1280,
        # 1280:1280, 2560:1080, 1080:2560 sind alle KEINE Runway-Ratios).
        # Quelle: Bug-Report claude_mouse v0.10.9. Runway gruppiert die
        # supported ratios offenbar nach Aufloesungs-Stufen:
        #   ~512-Stufe:   992:432, 864:496, 752:560, 640:640, 560:752,
        #                  496:864
        #   ~720-Stufe:   1470:630, 1280:720, 1112:834, 960:960, 834:1112,
        #                  720:1280
        #   ~1080-Stufe: 2206:946, 1920:1080, 1664:1248, 1440:1440,
        #                  1248:1664, 1080:1920
        supported_ratios=(
            # 512er-Stufe
            "992:432", "864:496", "752:560", "640:640", "560:752", "496:864",
            # 720er-Stufe
            "1470:630", "1280:720", "1112:834", "960:960", "834:1112", "720:1280",
            # 1080er-Stufe
            "2206:946", "1920:1080", "1664:1248", "1440:1440", "1248:1664", "1080:1920",
        ),
        max_characters_in_frame=3,  # API-Limit: 9 Reference Images. Stabilität-Heuristik: 3.
        supports_keyframe_start=True,
        supports_keyframe_end=True,
        supports_image_to_video=True,
        notes="Modi (Runway-API live 2026-05-31): References / Start-End frames / Text-to-Video. "
              "Duration 4-15 s (Provider rundet kuerzere Shots auf 4 s auf, "
              "Mehr-Sekunden werden berechnet). Output 480p/720p/1080p — supported_ratios "
              "decken alle drei Aufloesungs-Stufen ab. Bis zu 9 Reference Images "
              "(.jpg/.jpeg/.png/.webm, 300-6000 px, <30 MB). "
              "max_characters_in_frame=3 ist eine Stabilitäts-Heuristik fürs Bild — "
              "konsistente Darstellung aller Figuren im selben Frame degradiert ab 3+.",
    ),
    "veo3": ModelCapability(
        max_duration_s=8.0,
        supported_ratios=("1280:720", "720:1280"),
        max_characters_in_frame=4,
        supports_keyframe_start=False,
        supports_keyframe_end=False,
        supports_image_to_video=False,
        notes="Text-to-video only, keine Keyframes. Hohes Motion-Detail, teuer.",
    ),
    "veo3.1_fast": ModelCapability(
        max_duration_s=8.0,
        supported_ratios=("1280:720", "720:1280"),
        max_characters_in_frame=3,
        supports_keyframe_start=False,
        supports_keyframe_end=False,
        supports_image_to_video=False,
        notes="Schnellere, günstigere Veo3-Variante.",
    ),
    # ----- fal.ai Modelle (v0.11.0) -----
    #
    # Aspect-Ratios bei fal sind semantisch: '16:9', '9:16', '1:1', '4:3',
    # '3:4', '21:9'. Resolution wird separat als Parameter uebergeben
    # ('480p', '720p', '1080p'). Wir tragen hier alle semantischen
    # Ratios ein — der Builder/Dispatcher uebergibt die String-Form direkt
    # ohne float-Aware-Lookup (fal akzeptiert Klartext).
    "fal:bytedance/seedance-2.0": ModelCapability(
        max_duration_s=15.0,
        supported_ratios=("16:9", "9:16", "1:1", "4:3", "3:4", "21:9"),
        max_characters_in_frame=4,
        supports_keyframe_start=True,
        supports_keyframe_end=True,
        supports_image_to_video=True,
        supports_reference_mode=True,
        max_reference_images=9,
        notes="Seedance 2.0 Pro auf fal.ai. Drei Modi (mutually exclusive): "
              "text-to-video, image-to-video (Keyframe first/last), "
              "reference-to-video (bis 9 Bilder + 3 Videos + 3 Audio "
              "per @image1-Mention). Resolutions 480p/720p/1080p, "
              "Duration 4-15 s. Audio-Lip-Sync moeglich.",
    ),
    "fal:bytedance/seedance-2.0/fast": ModelCapability(
        max_duration_s=15.0,
        supported_ratios=("16:9", "9:16", "1:1", "4:3", "3:4", "21:9"),
        max_characters_in_frame=4,
        supports_keyframe_start=True,
        supports_keyframe_end=True,
        supports_image_to_video=True,
        supports_reference_mode=True,
        max_reference_images=9,
        notes="Seedance 2.0 Fast — gleicher Feature-Set wie Pro, "
              "guenstigere/schnellere Inferenz, leicht reduzierte Qualitaet. "
              "Empfohlen fuer Previews.",
    ),
}


def capability(model: str) -> ModelCapability:
    if model not in MODEL_CAPABILITIES:
        raise KeyError(
            f"Unbekanntes Video-Modell {model!r}. Registriere in musicvideo.common.models."
        )
    return MODEL_CAPABILITIES[model]
