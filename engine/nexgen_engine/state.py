"""Read-only project-state aggregator — the engine's view of where a project stands:
project meta, gate/phase status, and the next open phase. This grows (per-shot status,
budget spent) as those modules extract. Powers the engine MCP's `get_project_state`.
"""

from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel

from nexgen_engine.core import gates as gates_mod
from nexgen_engine.core import project as project_mod
from nexgen_engine.core.gates import CORE_PHASES


class PhaseStatus(BaseModel):
    phase: str
    approved: bool


class ProjectState(BaseModel):
    project: str
    mode: str
    budget_eur: float
    phases: list[PhaseStatus]
    next_phase: str | None


def build_snapshot(project_dir: Path, phase_order: tuple[str, ...] = CORE_PHASES) -> ProjectState:
    meta = project_mod.load(project_dir)
    g = gates_mod.load(project_dir)
    phases = [PhaseStatus(phase=p, approved=g.get(p).approved) for p in phase_order]
    next_phase = next((p.phase for p in phases if not p.approved), None)
    return ProjectState(
        project=meta.project,
        mode=meta.mode.value,
        budget_eur=meta.budget_eur,
        phases=phases,
        next_phase=next_phase,
    )
