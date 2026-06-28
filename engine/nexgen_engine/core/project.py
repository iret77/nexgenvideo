"""Project metadata (project.yaml): mode + budget per project."""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

import yaml
from pydantic import BaseModel, ConfigDict, Field

from nexgen_engine.core.modes import Mode


class ProjectMeta(BaseModel):
    model_config = ConfigDict(extra="forbid")

    project: str
    mode: Mode
    budget_eur: Annotated[float, Field(gt=0)] = 50.0
    created: str | None = None


def load(project_dir: Path) -> ProjectMeta:
    path = project_dir / "project.yaml"
    if not path.exists():
        raise FileNotFoundError(f"{path} missing — set mode/budget via project init")
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
    return ProjectMeta.model_validate(data)


def save(project_dir: Path, meta: ProjectMeta) -> Path:
    path = project_dir / "project.yaml"
    with path.open("w", encoding="utf-8") as f:
        yaml.safe_dump(
            meta.model_dump(exclude_none=True, mode="json"),
            f,
            sort_keys=False,
            allow_unicode=True,
        )
    return path
