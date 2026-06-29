"""Per-project approval gates — the generic mechanism.

Every phase must be explicitly approved by the user before the next step runs; the
render dispatcher checks this hard. The gate *mechanism* is core; the gate *set +
order* are not hardcoded — the engine ships the core production phases and a pack
adds its own (e.g. music `analysis`) via the pack contract. (Extracted from
musicvideo `common.gates`; the fixed per-phase pydantic fields became a phase->gate
dict so the set is open.)
"""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

import yaml
from pydantic import BaseModel, ConfigDict, Field

#: The generic core production pipeline, in order. A pack inserts/extends it
#: (music adds "analysis" after project_init).
CORE_PHASES: tuple[str, ...] = (
    "project_init",
    "brief",
    "production_design",
    "treatment",
    "storyboard",
    "bible",
    "shotlist",
    "sanity",
    "frames",
    "render",
)


class Gate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    approved: bool = False
    approved_at: str | None = None
    approved_by: str | None = None
    notes: str | None = None


class Gates(BaseModel):
    model_config = ConfigDict(extra="forbid")

    project: str
    schema_: str = Field(alias="schema", default="gates/v2")
    gates: dict[str, Gate] = Field(default_factory=dict)

    def get(self, phase: str) -> Gate:
        return self.gates.get(phase, Gate())

    def set(self, phase: str, gate: Gate) -> None:
        self.gates[phase] = gate


class GateBlocked(RuntimeError):
    """Raised when a required gate is not approved."""


def _path(project_dir: Path) -> Path:
    return project_dir / "gates.yaml"


def load(project_dir: Path) -> Gates:
    p = _path(project_dir)
    if not p.exists():
        g = Gates(project=project_dir.name)
        save(project_dir, g)
        return g
    return Gates.model_validate(yaml.safe_load(p.read_text(encoding="utf-8")))


def save(project_dir: Path, gates: Gates) -> Path:
    p = _path(project_dir)
    p.write_text(
        yaml.safe_dump(
            gates.model_dump(by_alias=True, exclude_none=True, mode="json"),
            sort_keys=False,
            allow_unicode=True,
        ),
        encoding="utf-8",
    )
    return p


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def approve(project_dir: Path, phase: str, notes: str | None = None, by: str = "user") -> Gates:
    g = load(project_dir)
    g.set(phase, Gate(approved=True, approved_at=_now(), approved_by=by, notes=notes))
    save(project_dir, g)
    return g


def reset(project_dir: Path, phase: str) -> Gates:
    g = load(project_dir)
    g.set(phase, Gate())
    save(project_dir, g)
    return g


def require(project_dir: Path, phase: str) -> Gate:
    g = load(project_dir)
    gate = g.get(phase)
    if not gate.approved:
        raise GateBlocked(
            f"Gate {phase!r} not approved for project {g.project!r}. Claude must get "
            f"explicit user approval (AskUserQuestion) before continuing, then set the gate."
        )
    return gate


def rewind_to(project_dir: Path, target: str, order: tuple[str, ...] = CORE_PHASES) -> list[str]:
    """Reset the target gate and every following gate to approved=false. Artifacts are
    kept (versioned history); a re-run writes a new version. Returns the reset phases."""
    g = load(project_dir)
    if target not in order:
        raise ValueError(f"unknown gate {target!r}; allowed: {list(order)}")
    stamp = _now()
    affected: list[str] = []
    for phase in order[order.index(target):]:
        g.set(phase, Gate(approved=False, notes=f"rewound @ {stamp}"))
        affected.append(phase)
    save(project_dir, g)
    return affected
