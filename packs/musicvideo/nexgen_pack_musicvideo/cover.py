"""Cover-Manifest pro Format (cover/<format>.yaml).

Klein gehalten — pro Format Single-Artefakt. Tracking nur: Pfade,
verwendete Prompts, Modell, Text-Overlay-Parameter.

v0.10.20: Multi-Format-Support. Ein Manifest pro Format
(`square`, `landscape`, `portrait`). Vorher: ein cover.yaml
(deprecated, Loader liest beides).
"""

from __future__ import annotations

from pathlib import Path
from typing import Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field

COVER_SCHEMA_VERSION = "cover/v2"

FormatKey = Literal["square", "landscape", "portrait"]

# Format -> Aspect-Ratio + Streaming-Plattform-Kontext.
FORMAT_ASPECT: dict[str, str] = {
    "square": "1:1",       # Spotify, Apple Music, Bandcamp, Instagram Post
    "landscape": "16:9",   # YouTube Thumbnail, Facebook Cover
    "portrait": "9:16",    # TikTok, Instagram Reels/Story, YouTube Shorts
}

FORMAT_PLATFORM_HINT: dict[str, str] = {
    "square": "Streaming (Spotify/Apple Music/Bandcamp) und Instagram-Feed-Post",
    "landscape": "YouTube-Thumbnail, Facebook-Cover",
    "portrait": "TikTok, Instagram Reels/Story, YouTube Shorts",
}


class CoverClean(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str  # relativ zu projects/<name>/
    prompt: str
    """User-facing Log-Notiz."""
    provider_prompt: str
    """Echter Prompt an den Provider — fuer Reproduzierbarkeit + Audit."""
    model_id: str
    multi_ref_hints: list[str] = Field(default_factory=list)


class TextOverlay(BaseModel):
    model_config = ConfigDict(extra="forbid")
    artist: str
    title: str
    renderer: Literal["pillow", "gpt_image_2"] = "gpt_image_2"
    """Text-Rendering-Pfad.

    - `gpt_image_2` (Default): generiert das Bild MIT Text per GPT
      Image 2 (April-2026-Modell). Bevorzugt, weil OpenAIs Modell
      Text deutlich zuverlaessiger rendert als Nano Banana / Imagen
      (User-Anweisung 2026-05-31). Kostet einen Provider-Call.
    - `pillow`: deterministisches Overlay mit Pillow auf das clean
      Cover. 100% korrekt, aber Text wirkt aufgesetzt — kein
      Modell-integriertes Design.
    """
    layout: Literal["bottom", "top", "center"] = "bottom"
    font_family: str = "Helvetica"
    """Nur fuer `renderer=pillow` relevant. GPT-Image-2-Pfad ignoriert."""
    text_color: Literal["white", "black", "auto"] = "auto"
    """Nur fuer `renderer=pillow` relevant. `auto` = automatisch
    hell/dunkel je nach Hintergrund-Helligkeit."""


class CoverText(BaseModel):
    model_config = ConfigDict(extra="forbid")
    path: str  # relativ zu projects/<name>/
    overlay: TextOverlay


class CoverManifest(BaseModel):
    """Cover-Manifest pro Format. Ein Format = ein YAML unter
    cover/<format>.yaml."""
    model_config = ConfigDict(extra="forbid")
    schema_: str = Field(alias="schema", default=COVER_SCHEMA_VERSION)
    project: str
    format: FormatKey = "square"
    generated: str
    clean: CoverClean | None = None
    text: CoverText | None = None


def _path(project_dir: Path, format: str = "square") -> Path:
    # Legacy-Pfad cover/cover.yaml zaehlt als square (v0.10.19 hatte
    # nur ein Format). Wenn neuer Pfad nicht existiert, faellt der
    # Loader unten zurueck.
    return project_dir / "cover" / f"{format}.yaml"


def _legacy_path(project_dir: Path) -> Path:
    return project_dir / "cover" / "cover.yaml"


def load(project_dir: Path, format: str = "square") -> CoverManifest | None:
    p = _path(project_dir, format)
    if p.exists():
        data = yaml.safe_load(p.read_text(encoding="utf-8"))
        return CoverManifest.model_validate(data)
    # Fallback: alter v0.10.19-Pfad cover.yaml fuer square
    if format == "square":
        legacy = _legacy_path(project_dir)
        if legacy.exists():
            data = yaml.safe_load(legacy.read_text(encoding="utf-8"))
            data.setdefault("format", "square")
            data["schema"] = COVER_SCHEMA_VERSION
            return CoverManifest.model_validate(data)
    return None


def save(project_dir: Path, manifest: CoverManifest) -> Path:
    p = _path(project_dir, manifest.format)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(
        yaml.safe_dump(
            manifest.model_dump(by_alias=True, exclude_none=True, mode="json"),
            sort_keys=False,
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    return p
