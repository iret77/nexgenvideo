"""The Intent Ledger (ledger/schema.py + the `ledger` read kind)."""

import json
import subprocess
import sys
import os
from pathlib import Path

import pytest

from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.ledger import schema as ledger


def _project(tmp_path: Path) -> Path:
    return layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)


def test_empty_ledger_loads_as_default(tmp_path: Path):
    data_root = _project(tmp_path)
    led = ledger.load(data_root)
    assert led.objects == {}
    assert led.schema_ == "ledger/v1"


def test_set_attribute_roundtrip_and_reconcile(tmp_path: Path):
    data_root = _project(tmp_path)
    out = ledger.set_attribute(
        data_root, "character", "mara", "wardrobe",
        tag="Faded red canvas jacket", source="keep her red jacket",
    )
    assert out["object"] == "character:mara"
    assert out["attribute"]["directive"] == "Faded red canvas jacket"  # defaults to tag
    assert out["attribute"]["locked"] is False

    # Update reconciles the same key; source survives when not re-given; lock survives too.
    ledger.set_locked(data_root, "character", "mara", "wardrobe", True)
    out = ledger.set_attribute(data_root, "character", "mara", "wardrobe", tag="Red jacket, worn")
    assert out["attribute"]["locked"] is True
    assert out["attribute"]["source"] == "keep her red jacket"
    led = ledger.load(data_root)
    assert list(led.objects["character:mara"].keys()) == ["wardrobe"]


def test_singletons_need_no_object_id_and_entities_do(tmp_path: Path):
    data_root = _project(tmp_path)
    out = ledger.set_attribute(data_root, "look", None, "grain", tag="Heavy 16mm grain")
    assert out["object"] == "look"
    with pytest.raises(ValueError):
        ledger.set_attribute(data_root, "shot", None, "pace", tag="Slow")
    with pytest.raises(ValueError):
        ledger.set_attribute(data_root, "vibe", "x", "k", tag="t")


def test_locked_attribute_refuses_removal_until_unlocked(tmp_path: Path):
    data_root = _project(tmp_path)
    ledger.set_attribute(data_root, "shot", "s001", "framing", tag="Low angle", locked=True)
    with pytest.raises(ValueError, match="locked"):
        ledger.remove_attribute(data_root, "shot", "s001", "framing")
    ledger.set_locked(data_root, "shot", "s001", "framing", False)
    out = ledger.remove_attribute(data_root, "shot", "s001", "framing")
    assert out["removed"] is True
    assert ledger.load(data_root).objects == {}


def test_read_cli_ledger_kind(tmp_path: Path):
    data_root = _project(tmp_path)
    ledger.set_attribute(data_root, "character", "mara", "wardrobe", tag="Red jacket", locked=True)
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        p for p in (str(Path(__file__).resolve().parent.parent), env.get("PYTHONPATH", "")) if p
    )
    proc = subprocess.run(
        [sys.executable, "-m", "nexgen_engine.read", "ledger", str(data_root)],
        capture_output=True, text=True, env=env,
    )
    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout)
    assert data["schema"] == "ledger/v1"
    assert data["objects"]["character:mara"]["wardrobe"]["locked"] is True
