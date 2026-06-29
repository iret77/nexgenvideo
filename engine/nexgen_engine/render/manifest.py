"""Per-shot render/frame manifest — the generic, format-neutral ledger of which
shots have been rendered, where their outputs live, and what they cost.

The embedded agent drives generation shot-by-shot: it asks for the next unrendered
shot, calls nexgen's own `generateImage`/`generateVideo` for the actual provider
work, then records the result here. This module knows nothing about music (or any
format) — it deals only in shot IDs, outputs, costs, and phases. Shotlist order is
supplied by the caller (a list of shot IDs); the manifest itself never reads a
shotlist.

Persistence: `renders/manifest-<phase>.json`. The on-disk JSON keeps the legacy
monolith shape (`{"project", "phase", "shots":[{"shot_id", "status", "eur_spent",
"out_path", ...}]}`) for continuity with the existing readers
(`render.costs.already_spent_in_project`, `show.formatters.show_renders`).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

SCHEMA_VERSION = "render_manifest/v1"
RENDERS_SUBDIR = "renders"

RenderStatus = Literal["pending", "rendered", "failed"]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class RenderEntry(BaseModel):
    model_config = ConfigDict(extra="ignore")

    shot_id: str
    phase: str
    status: RenderStatus = "pending"
    output: str | None = None
    """Local path or remote URL of the rendered artifact, or None if not done."""
    cost_eur: float = 0.0
    updated_at: str | None = None


class RenderManifest(BaseModel):
    model_config = ConfigDict(extra="ignore")

    project: str
    phase: str
    schema_: str = Field(alias="schema", default=SCHEMA_VERSION)
    entries: dict[str, RenderEntry] = Field(default_factory=dict)


def manifest_path(project_dir: Path, phase: str) -> Path:
    return project_dir / RENDERS_SUBDIR / f"manifest-{phase}.json"


def _to_disk(manifest: RenderManifest) -> dict:
    """Serialize to the legacy monolith JSON shape so existing readers keep working.

    Each shot row carries both the canonical fields (status, output, cost_eur,
    updated_at) and the legacy mirror keys (eur_spent, out_path) that
    `costs.already_spent_in_project` and `formatters.show_renders` read.
    """
    shots = []
    for entry in manifest.entries.values():
        shots.append(
            {
                "shot_id": entry.shot_id,
                "phase": entry.phase,
                "status": entry.status,
                "output": entry.output,
                "cost_eur": entry.cost_eur,
                "updated_at": entry.updated_at,
                # legacy mirror keys (read by costs.py + formatters.py)
                "eur_spent": entry.cost_eur,
                "out_path": entry.output,
            }
        )
    return {
        "project": manifest.project,
        "phase": manifest.phase,
        "schema": manifest.schema_,
        "shots": shots,
        # legacy formatter reads `results`; mirror `shots` under it.
        "results": shots,
    }


def _from_disk(data: dict) -> RenderManifest:
    rows = data.get("shots")
    if not isinstance(rows, list):
        rows = data.get("results") if isinstance(data.get("results"), list) else []
    entries: dict[str, RenderEntry] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        shot_id = row.get("shot_id")
        if not isinstance(shot_id, str):
            continue
        cost = row.get("cost_eur", row.get("eur_spent", 0.0)) or 0.0
        output = row.get("output", row.get("out_path"))
        entries[shot_id] = RenderEntry(
            shot_id=shot_id,
            phase=row.get("phase") or data.get("phase") or "",
            status=row.get("status", "pending"),
            output=output,
            cost_eur=float(cost),
            updated_at=row.get("updated_at"),
        )
    return RenderManifest(
        project=data.get("project", ""),
        phase=data.get("phase", ""),
        schema=data.get("schema", SCHEMA_VERSION),
        entries=entries,
    )


def load(project_dir: Path, phase: str) -> RenderManifest:
    """Load `renders/manifest-<phase>.json`, or an empty manifest if none exists."""
    path = manifest_path(project_dir, phase)
    if not path.exists():
        return RenderManifest(project=project_dir.name, phase=phase)
    data = json.loads(path.read_text(encoding="utf-8"))
    return _from_disk(data if isinstance(data, dict) else {})


def save(project_dir: Path, manifest: RenderManifest) -> Path:
    """Write the manifest to `renders/manifest-<phase>.json`. Returns the path."""
    path = manifest_path(project_dir, manifest.phase)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(_to_disk(manifest), indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return path


def next_unrendered(ordered_shot_ids: list[str], manifest: RenderManifest) -> str | None:
    """First shot ID in shotlist order whose entry is missing or not `rendered`."""
    for shot_id in ordered_shot_ids:
        entry = manifest.entries.get(shot_id)
        if entry is None or entry.status != "rendered":
            return shot_id
    return None


def record(
    manifest: RenderManifest,
    shot_id: str,
    *,
    output: str | None,
    cost_eur: float,
    status: RenderStatus = "rendered",
    phase: str,
    updated_at: str | None = None,
) -> RenderManifest:
    """Upsert the entry for *shot_id* and return the manifest (mutated in place).

    `updated_at` is stamped with the current UTC time when not supplied — pass an
    explicit value for deterministic tests."""
    manifest.entries[shot_id] = RenderEntry(
        shot_id=shot_id,
        phase=phase,
        status=status,
        output=output,
        cost_eur=cost_eur,
        updated_at=updated_at if updated_at is not None else _now(),
    )
    return manifest


def spent(manifest: RenderManifest) -> float:
    """Sum of `cost_eur` across all entries."""
    return round(sum(e.cost_eur for e in manifest.entries.values()), 2)


def summary(ordered_shot_ids: list[str], manifest: RenderManifest) -> dict:
    """Aggregate counts + spend: {total, rendered, pending, failed, spent_eur}.

    `total` is the shotlist length. `pending` counts shots that are either missing
    an entry or carry a non-terminal status (anything not rendered/failed)."""
    rendered = failed = pending = 0
    for shot_id in ordered_shot_ids:
        entry = manifest.entries.get(shot_id)
        if entry is None:
            pending += 1
        elif entry.status == "rendered":
            rendered += 1
        elif entry.status == "failed":
            failed += 1
        else:
            pending += 1
    return {
        "total": len(ordered_shot_ids),
        "rendered": rendered,
        "pending": pending,
        "failed": failed,
        "spent_eur": spent(manifest),
    }
