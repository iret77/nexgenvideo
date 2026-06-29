from pathlib import Path

from nexgen_engine import mcp_server
from nexgen_engine.core import gates as gates_mod
from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.state import build_snapshot


def test_snapshot_tracks_next_open_phase(tmp_path: Path):
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.BEAT)
    snap = build_snapshot(data_root)
    assert snap.project == "demo"
    assert snap.mode == "beat"
    assert snap.next_phase == "project_init"  # nothing approved → first phase
    gates_mod.approve(data_root, "project_init")
    assert build_snapshot(data_root).next_phase == "brief"


def test_engine_mcp_surface():
    # The standard function-call surface is reachable without running a server.
    assert mcp_server.mcp.name == "engine"
    assert mcp_server.phases()[0] == "project_init"


def test_mcp_get_project_state(tmp_path: Path):
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)
    state = mcp_server.project_state(str(data_root))
    assert state["project"] == "demo"
    assert state["mode"] == "section"
    assert any(p["phase"] == "bible" for p in state["phases"])


def test_snapshot_includes_budget(tmp_path):
    from nexgen_engine.core import layout as layout_mod
    from nexgen_engine.core.modes import Mode
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.BEAT, budget_eur=80.0)
    snap = build_snapshot(data_root)
    assert snap.budget_eur == 80.0
    assert snap.budget_spent_eur == 0.0          # fresh project, nothing rendered
    assert snap.budget_remaining_eur == 80.0
