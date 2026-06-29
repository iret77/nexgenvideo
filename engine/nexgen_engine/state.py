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
from nexgen_engine.render import costs as costs_mod


class PhaseStatus(BaseModel):
    phase: str
    approved: bool


class ProjectState(BaseModel):
    project: str
    mode: str
    budget_eur: float
    budget_spent_eur: float
    budget_remaining_eur: float
    phases: list[PhaseStatus]
    next_phase: str | None


def build_snapshot(project_dir: Path, phase_order: tuple[str, ...] = CORE_PHASES) -> ProjectState:
    meta = project_mod.load(project_dir)
    g = gates_mod.load(project_dir)
    phases = [PhaseStatus(phase=p, approved=g.get(p).approved) for p in phase_order]
    next_phase = next((p.phase for p in phases if not p.approved), None)
    try:
        spent = costs_mod.already_spent_in_project(project_dir)
    except Exception:  # no render ledger yet (fresh project) → nothing spent
        spent = 0.0
    return ProjectState(
        project=meta.project,
        mode=meta.mode.value,
        budget_eur=meta.budget_eur,
        budget_spent_eur=spent,
        budget_remaining_eur=max(0.0, meta.budget_eur - spent),
        phases=phases,
        next_phase=next_phase,
    )
