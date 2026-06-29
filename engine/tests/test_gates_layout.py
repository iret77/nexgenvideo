from pathlib import Path

import pytest

from nexgen_engine.core import gates as gates_mod
from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core import project as project_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.pack import EngineRegistry


def test_gates_block_until_approved(tmp_path: Path):
    with pytest.raises(gates_mod.GateBlocked):
        gates_mod.require(tmp_path, "bible")
    gates_mod.approve(tmp_path, "bible", notes="ok")
    assert gates_mod.require(tmp_path, "bible").approved
    assert gates_mod.load(tmp_path).get("bible").approved is True


def test_rewind_resets_target_and_following(tmp_path: Path):
    for phase in ("treatment", "bible", "frames"):
        gates_mod.approve(tmp_path, phase)
    affected = gates_mod.rewind_to(tmp_path, "bible")
    g = gates_mod.load(tmp_path)
    assert g.get("treatment").approved is True   # before target → untouched
    assert g.get("bible").approved is False       # target + following → reset
    assert g.get("frames").approved is False
    assert affected == ["bible", "shotlist", "sanity", "frames", "render"]


def test_layout_creates_core_plus_pack_dirs(tmp_path: Path):
    reg = EngineRegistry()
    reg.register_project_dirs(["audio", "lyrics", "analysis"])  # a music pack's contribution

    home = tmp_path / "proj"
    data_root = layout_mod.init_project(
        home, "demo", mode=Mode.BEAT, extra_dirs=tuple(reg.project_dirs)
    )

    assert (data_root / "bible").is_dir()       # core
    assert (data_root / "treatment").is_dir()   # core
    assert (data_root / "audio").is_dir()       # pack
    assert (data_root / "analysis").is_dir()    # pack
    assert project_mod.load(data_root).project == "demo"
    assert (data_root / "gates.yaml").exists()
