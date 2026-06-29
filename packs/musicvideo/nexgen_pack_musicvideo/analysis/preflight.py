"""Pre-Analysis-Check: prüft VOR dem (teuren, mehrminütigen) Analyse-Lauf,
ob alle Eingangs-Artefakte vorhanden sind.

Regeln:
- Audio-Datei FEHLT  → harter Blocker, kein Analyse-Start.
- Lyrics FEHLEN       → Warnung (kein Alignment möglich; evtl. vergessen).
- Referenzbilder FEHLEN → Warnung (Bible/Production-Design ohne Material).

Der Orchestrator ruft `preflight`, zeigt das Ergebnis und fragt bei
Warnungen nach, ob etwas vergessen wurde oder die Analyse bewusst ohne
diese Inputs starten soll.

Zweck: verhindert, dass jemand (auch der User selbst) eine 5-Minuten-
Analyse startet und erst danach merkt, dass das Lyrics-File fehlt.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

AUDIO_EXTS = {".wav", ".mp3", ".flac", ".m4a", ".aiff"}
IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".avif", ".heic", ".heif", ".gif"}


@dataclass
class PreflightResult:
    project: str
    audio_files: list[str] = field(default_factory=list)
    lyrics_path: str | None = None
    reference_images: list[str] = field(default_factory=list)
    blockers: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def has_audio(self) -> bool:
        return bool(self.audio_files)

    @property
    def has_lyrics(self) -> bool:
        return self.lyrics_path is not None

    @property
    def has_references(self) -> bool:
        return bool(self.reference_images)

    @property
    def can_start(self) -> bool:
        """Analyse darf nur starten, wenn keine Blocker vorliegen."""
        return not self.blockers

    @property
    def needs_user_confirmation(self) -> bool:
        """True wenn es Warnungen gibt, die der Orchestrator dem User
        vorlegen soll (vor dem teuren Lauf nachfragen)."""
        return bool(self.warnings)


def preflight(project_dir: Path) -> PreflightResult:
    """Prüfe die Eingangs-Artefakte eines Projekts vor der Analyse."""
    from nexgen_engine.core.paths import display_name

    result = PreflightResult(project=display_name(project_dir))

    # 1. Audio (harter Blocker)
    audio_dir = project_dir / "audio"
    if audio_dir.is_dir():
        result.audio_files = sorted(
            p.name
            for p in audio_dir.iterdir()
            if p.is_file() and p.suffix.lower() in AUDIO_EXTS
        )
    if not result.audio_files:
        result.blockers.append(
            "Keine Audio-Datei in audio/ (.wav/.mp3/.flac/.m4a/.aiff). "
            "Ohne Song keine Analyse — bitte Audio per SFTP nach "
            f"{project_dir / 'audio'}/ ablegen."
        )

    # 2. Lyrics (Warnung)
    lyrics_file = project_dir / "lyrics" / "lyrics.txt"
    if lyrics_file.exists() and lyrics_file.stat().st_size > 0:
        result.lyrics_path = str(lyrics_file.relative_to(project_dir))
    else:
        result.warnings.append(
            "Keine Lyrics (lyrics/lyrics.txt fehlt oder leer). Ohne Lyrics "
            "kein Forced-Alignment, Section-Grenzen werden nur akustisch "
            "erkannt. Falls der Song Text hat: Lyrics bereitstellen lohnt sich."
        )

    # 3. Referenzbilder (Warnung) — irgendwo unter import/
    import_dir = project_dir / "import"
    if import_dir.is_dir():
        for p in import_dir.rglob("*"):
            if p.is_file() and p.suffix.lower() in IMAGE_EXTS:
                result.reference_images.append(str(p.relative_to(project_dir)))
    result.reference_images.sort()
    if not result.reference_images:
        result.warnings.append(
            "Keine Referenzbilder in import/ gefunden. Production-Design und "
            "Bible müssen dann ohne visuelles Ausgangsmaterial arbeiten. "
            "Falls Charakter-/Location-/Moodboard-Bilder existieren: nach "
            f"{project_dir / 'import'}/ ablegen."
        )

    return result
