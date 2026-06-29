from pathlib import Path

from nexgen_engine import mcp_server
from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.shotlist import schema as shotlist_schema


def _minimal_shotlist() -> shotlist_schema.Shotlist:
    shot = shotlist_schema.Shot(
        id="s001",
        section="verse",
        time_start=0.0,
        time_end=4.0,
        duration_s=4.0,
        type=shotlist_schema.ShotType.PERFORMANCE,
        description="d",
        visual_prompt="p",
        mood="m",
    )
    song = shotlist_schema.Song(
        title="t",
        audio_path="a.wav",
        analysis_path="an.json",
        bpm=120.0,
        duration_s=4.0,
    )
    return shotlist_schema.Shotlist(
        schema=shotlist_schema.SCHEMA_VERSION,
        mode=Mode.SECTION,
        project="demo",
        song=song,
        generated="2026-01-01",
        generator="test",
        shots=[shot],
    )


def test_run_sanity_no_shotlist_returns_error(tmp_path: Path):
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)
    result = mcp_server.run_sanity(str(data_root))
    assert result["error"] == "no shotlist"
    assert "findings" not in result


def test_run_sanity_returns_report(tmp_path: Path):
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)
    written = shotlist_schema.save(data_root, _minimal_shotlist())
    assert written == data_root / "shotlist" / "v1.yaml"

    # Round-trip via the loader returns the latest versioned shotlist.
    loaded = shotlist_schema.load(data_root)
    assert loaded is not None
    assert loaded.shots[0].id == "s001"

    report = mcp_server.run_sanity(str(data_root))
    assert report["project"] == "demo"
    assert isinstance(report["findings"], list)
    for f in report["findings"]:
        assert set(f) == {"level", "code", "shot_id", "message"}
    # The minimal "p" prompt trips the core PROMPT_TOO_SHORT check, proving
    # engine-core checks actually ran.
    assert any(f["code"] == "PROMPT_TOO_SHORT" for f in report["findings"])


def test_save_picks_next_version(tmp_path: Path):
    data_root = layout_mod.init_project(tmp_path / "p", "demo", mode=Mode.SECTION)
    shotlist_schema.save(data_root, _minimal_shotlist())
    second = shotlist_schema.save(data_root, _minimal_shotlist())
    assert second == data_root / "shotlist" / "v2.yaml"
    assert shotlist_schema.latest_version(data_root) == 2


def test_run_sanity_tool_registered():
    # The plain function is importable/callable and the MCP tool is registered.
    assert callable(mcp_server.run_sanity)
    assert mcp_server.run_sanity_tool.__name__ == "run_sanity_tool"
