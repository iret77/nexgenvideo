"""Zentrale Komptabilitaets-Matrix fuer Skill-Schema-Versionen.

Hintergrund: Der Skill wird per `git pull` aktualisiert, Projekte aber
bleiben in ihrem Zustand. Wenn ein Skill mit einer Projekt-Schema-Version
konfrontiert wird, die er nicht kennt, riskieren wir stille Datenkorruption
(neue Pflichtfelder fehlen, alte Felder werden falsch interpretiert).

Drei Faelle:
- **Projekt-Version <= Skill-Version**: Skill kennt das Schema, kann lesen.
  Wenn niedriger → Migration moeglich (siehe `<modul>.migrate`).
- **Projekt-Version == Skill-Version**: alles in Ordnung.
- **Projekt-Version > Skill-Version**: HART STOPPEN. Skill verweigert
  Weiterarbeit, User soll Skill aktualisieren (git pull + CLAUDE.md neu
  einlesen).

Dieses Modul ist die Single Source of Truth fuer „was der aktuelle Skill
kennt". Wer ein Schema bumpen will, traegt es hier ein UND schreibt die
Migration.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import yaml

# ---------------------------------------------------------------------------
# Komptabilitaets-Matrix
# ---------------------------------------------------------------------------
#
# Pro Schema:
#   `current`     — Was der Skill HEUTE schreibt.
#   `supported`   — Was der Skill (per Migration / Tolerant-Reader) lesen kann.
#                    `current` ist immer in `supported`.
#
# Versionierungs-Pattern: `<name>/v<N>` (z.B. `bible/v5`).

SCHEMA_MATRIX: dict[str, dict[str, object]] = {
    "bible": {
        "current": "bible/v5",
        "supported": ("bible/v4", "bible/v5"),
    },
    "shotlist": {
        "current": "shotlist/v3",
        "supported": ("shotlist/v1", "shotlist/v2", "shotlist/v3"),
    },
    "brief": {
        "current": "brief/v1",
        "supported": ("brief/v1",),
    },
    "frame_audit": {
        "current": "frame_audit/v1",
        "supported": ("frame_audit/v1",),
    },
    # Treatment hat kein versioniertes schema-Feld (Markdown + Frontmatter),
    # daher nicht in der Matrix.
    # Storyboard nutzt YAML, Schema-String `storyboard/v1` — versionsstabil
    # bis substanziell verändert.
    "storyboard": {
        "current": "storyboard/v1",
        "supported": ("storyboard/v1",),
    },
}


VersionStatus = Literal["match", "behind", "ahead", "unknown", "missing"]


@dataclass(frozen=True)
class VersionFinding:
    """Befund pro Projekt-Artefakt vs. Skill-Matrix."""
    artifact: str
    """z.B. 'bible.yaml', 'shotlist/current.yaml', 'brief.yaml'."""
    schema_field: str
    """Schluessel in SCHEMA_MATRIX, z.B. 'bible'."""
    project_version: str | None
    """Version-String aus dem Projekt-File, oder None wenn File fehlt."""
    skill_current: str
    """Was der Skill heute schreibt."""
    status: VersionStatus
    """match | behind (Migration moeglich) | ahead (Skill veraltet, HART STOP) |
    unknown (Version-String unbekannt) | missing (File existiert nicht)."""
    message: str


def _parse_v(s: str) -> int | None:
    """`bible/v5` -> 5. None wenn nicht parsebar."""
    if not s or "/v" not in s:
        return None
    try:
        return int(s.rsplit("/v", 1)[1])
    except ValueError:
        return None


def _classify(project_v: str | None, schema_key: str) -> tuple[VersionStatus, str]:
    info = SCHEMA_MATRIX[schema_key]
    current = info["current"]  # type: ignore[index]
    supported = info["supported"]  # type: ignore[index]
    if project_v is None:
        return "missing", f"File fehlt — Skill schreibt '{current}'."
    if project_v == current:
        return "match", f"OK — beide auf '{current}'."
    if project_v in supported:
        return "behind", (
            f"Projekt auf '{project_v}', Skill aktuell '{current}'. "
            f"Migration empfohlen (siehe `<modul> migrate`)."
        )
    # Nicht supported. Numerisch vergleichen, um 'ahead' vs 'unknown' zu trennen.
    p = _parse_v(project_v)
    c = _parse_v(current)  # type: ignore[arg-type]
    if p is not None and c is not None and p > c:
        return "ahead", (
            f"Projekt auf '{project_v}', Skill kennt nur bis '{current}'. "
            "Skill ist veraltet — HART STOP. "
            "Aktualisiere den Skill (`git pull` im Skill-Repo) und lies "
            "CLAUDE.md neu, bevor Du an diesem Projekt weiterarbeitest."
        )
    return "unknown", (
        f"Projekt deklariert '{project_v}', aber das ist weder current "
        f"('{current}') noch in supported {supported}. "
        "Manuelle Klärung nötig."
    )


def _read_schema_field(path: Path) -> str | None:
    if not path.exists():
        return None
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (yaml.YAMLError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    v = data.get("schema")
    return v if isinstance(v, str) else None


# Mapping von Projekt-Dateipfad → Schema-Key
_ARTIFACTS: tuple[tuple[str, str], ...] = (
    ("bible/bible.yaml", "bible"),
    ("shotlist/current.yaml", "shotlist"),
    ("brief.yaml", "brief"),
    ("storyboard/current.yaml", "storyboard"),
)


def check_project_versions(project_dir: Path) -> list[VersionFinding]:
    """Pruefe alle bekannten Projekt-Artefakte gegen die Skill-Matrix.

    Findet keine `frame_audit/*.yaml`-Files automatisch — die werden
    pro Render geschrieben und entstehen erst dynamisch. Ihr Schema
    bleibt bislang v1.
    """
    findings: list[VersionFinding] = []
    for rel_path, schema_key in _ARTIFACTS:
        path = project_dir / rel_path
        proj_v = _read_schema_field(path)
        status, msg = _classify(proj_v, schema_key)
        findings.append(VersionFinding(
            artifact=rel_path,
            schema_field=schema_key,
            project_version=proj_v,
            skill_current=SCHEMA_MATRIX[schema_key]["current"],  # type: ignore[arg-type]
            status=status,
            message=msg,
        ))
    return findings


def any_ahead(findings: list[VersionFinding]) -> bool:
    """Mindestens ein Artefakt deklariert eine Version, die der Skill nicht
    kennt — Phase-Code soll dann hart abbrechen."""
    return any(f.status == "ahead" for f in findings)
