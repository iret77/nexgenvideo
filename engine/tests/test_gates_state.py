"""Multi-state gates + the new read kinds (W-A)."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from nexgen_engine.core import gates as gates_mod
from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.modes import Mode


def _project(tmp_path: Path) -> Path:
    return layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)


def _run(*args: str) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        p for p in (str(Path(__file__).resolve().parent.parent), env.get("PYTHONPATH", "")) if p
    )
    return subprocess.run(
        [sys.executable, "-m", "nexgen_engine.read", *args],
        capture_output=True, text=True, env=env,
    )


def test_set_state_needs_revision_keeps_phase_blocked(tmp_path: Path):
    root = _project(tmp_path)
    g = gates_mod.set_state(root, "storyboard", "needs_revision", notes="pacing too flat")
    gate = g.get("storyboard")
    assert gate.approved is False
    assert gate.state == "needs_revision"
    assert gate.notes == "pacing too flat"


def test_set_state_approved_with_notes_unblocks(tmp_path: Path):
    root = _project(tmp_path)
    g = gates_mod.set_state(root, "bible", "approved_with_notes", notes="tighten the prop list")
    assert g.get("bible").approved is True
    assert g.get("bible").state == "approved_with_notes"


def test_legacy_approve_derives_state(tmp_path: Path):
    root = _project(tmp_path)
    gates_mod.approve(root, "brief")
    assert gates_mod.load(root).get("brief").state == "approved"
    gates_mod.approve(root, "treatment", notes="ok with caveats")
    assert gates_mod.load(root).get("treatment").state == "approved_with_notes"


def test_invalid_state_rejected(tmp_path: Path):
    root = _project(tmp_path)
    with pytest.raises(ValueError, match="state must be one of"):
        gates_mod.set_state(root, "brief", "vibes")


def test_project_state_carries_gate_state(tmp_path: Path):
    root = _project(tmp_path)
    gates_mod.set_state(root, "brief", "needs_revision", notes="try again")
    proc = _run("state", str(root))
    data = json.loads(proc.stdout)
    brief = next(p for p in data["phases"] if p["phase"] == "brief")
    assert brief["state"] == "needs_revision"
    assert brief["notes"] == "try again"


def test_read_brief_and_treatment_null_when_absent(tmp_path: Path):
    root = _project(tmp_path)
    for kind in ("brief", "treatment"):
        proc = _run(kind, str(root))
        assert proc.returncode == 0, proc.stderr
        assert json.loads(proc.stdout) is None


def test_read_cost_includes_next_phase(tmp_path: Path):
    root = _project(tmp_path)
    proc = _run("cost", str(root))
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["next_phase"] == "project_init"
    assert "remaining_eur" in data
