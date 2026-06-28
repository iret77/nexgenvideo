"""Treatment (K3): versionierte Regie-Treatments vor der Shotlist.

Ein Treatment ist primär Prosa (Markdown) mit einem kleinen strukturierten
Header. Versionen werden NICHT überschrieben — `projects/<name>/treatment/v1.md`,
`v2.md`, ... parallel gepflegt. Das aktuell gültige steht in `current.md`
(Symlink oder Kopie des neuesten).
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Annotated, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field

TREATMENT_SCHEMA_VERSION = "treatment/v1"

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n(.*)$", re.DOTALL)


class TreatmentMeta(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_: str = Field(alias="schema", default=TREATMENT_SCHEMA_VERSION)
    project: str
    version: Annotated[int, Field(ge=1)]
    generated: str
    origin: Literal[
        "agent_proposal",
        "agent_revision",
        "user_supplied",
        "user_revision",
        # Brainstorm-Modus: gewählte Variante eines der drei Provider
        "brainstorm_claude",
        "brainstorm_openai",
        "brainstorm_gemini",
        # Brainstorm-Modus: Konsens-Variante aus mehreren Provider-Outputs
        "brainstorm_synthesis",
    ]
    generator: str
    summary_oneline: str
    title: str | None = None
    notes: str | None = None


class Treatment(BaseModel):
    model_config = ConfigDict(extra="forbid")

    meta: TreatmentMeta
    body_markdown: str


def _treatment_dir(project_dir: Path) -> Path:
    d = project_dir / "treatment"
    d.mkdir(exist_ok=True)
    return d


def versions(project_dir: Path) -> list[int]:
    d = _treatment_dir(project_dir)
    out = []
    for p in d.glob("v*.md"):
        m = re.match(r"v(\d+)\.md", p.name)
        if m:
            out.append(int(m.group(1)))
    return sorted(out)


def next_version(project_dir: Path) -> int:
    vs = versions(project_dir)
    return (vs[-1] + 1) if vs else 1


def load(project_dir: Path, version: int | None = None) -> Treatment:
    """Lade Treatment-Version (default: neueste)."""
    d = _treatment_dir(project_dir)
    vs = versions(project_dir)
    if not vs:
        raise FileNotFoundError(
            f"Kein Treatment unter {d} — treatment-agent (K3) aufrufen"
        )
    v = version or vs[-1]
    path = d / f"v{v}.md"
    raw = path.read_text(encoding="utf-8")
    m = _FRONTMATTER_RE.match(raw)
    if not m:
        raise ValueError(f"{path}: fehlendes YAML-Frontmatter")
    meta_data = yaml.safe_load(m.group(1))
    meta = TreatmentMeta.model_validate(meta_data)
    return Treatment(meta=meta, body_markdown=m.group(2))


def save(project_dir: Path, treatment: Treatment) -> Path:
    d = _treatment_dir(project_dir)
    path = d / f"v{treatment.meta.version}.md"
    frontmatter = yaml.safe_dump(
        treatment.meta.model_dump(by_alias=True, exclude_none=True, mode="json"),
        sort_keys=False,
        allow_unicode=True,
    ).strip()
    content = f"---\n{frontmatter}\n---\n{treatment.body_markdown}"
    path.write_text(content, encoding="utf-8")
    # current.md als Kopie (Symlinks bei Windows oft lästig)
    (d / "current.md").write_text(content, encoding="utf-8")
    return path
