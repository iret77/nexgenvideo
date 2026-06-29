"""The generic `run_phase` MCP tool — dispatches to whatever phase runner a pack
registered, knowing nothing format-specific. These exercise the helper (the
`@mcp.tool` wrapper is a 1-line passthrough)."""

from pathlib import Path

from nexgen_engine import mcp_server
from nexgen_engine.pack import EngineRegistry, PackRegistry


def test_no_runner_phase_returns_note(tmp_path: Path):
    # Planning phases (brief/treatment/…) are agent-driven: no code runner.
    out = mcp_server.run_phase(str(tmp_path), "brief")
    assert out == {
        "phase": "brief",
        "runner": None,
        "note": "no code runner registered; this phase is agent-driven",
    }


def test_analysis_phase_degrades_gracefully(tmp_path: Path):
    # The musicvideo pack registers an `analysis` runner, but its DSP stack
    # (librosa, the [audio] extra) is absent in the test venv. Dispatching must
    # NOT raise — it returns a structured error instead.
    out = mcp_server.run_phase(str(tmp_path), "analysis")
    assert out["phase"] == "analysis"

    if out.get("ok"):
        # Unexpected here, but if deps were present, success is still valid.
        assert out["ok"] is True
    else:
        # The common case in CI: missing optional deps surface gracefully.
        assert out["error"] in {"missing_dependencies", "phase_failed"}
        assert "detail" in out
        if out["error"] == "missing_dependencies":
            assert "hint" in out


def test_success_path_dumps_result(tmp_path: Path, monkeypatch):
    # A tiny fake runner registered via a monkeypatched registry proves the
    # success path runs the runner and JSON-dumps its result.
    class _FakeModel:
        def model_dump(self, mode=None):
            return {"dumped": True, "mode": mode}

    seen: dict[str, Path] = {}

    def _fake_runner(project_dir: Path) -> _FakeModel:
        seen["project_dir"] = project_dir
        return _FakeModel()

    registry = PackRegistry()
    registry.engine = EngineRegistry()
    registry.engine.register_phase("fake", _fake_runner)
    monkeypatch.setattr(mcp_server, "discover_packs", lambda: registry)

    out = mcp_server.run_phase(str(tmp_path), "fake")
    assert out == {
        "phase": "fake",
        "ok": True,
        "result": {"dumped": True, "mode": "json"},
    }
    assert seen["project_dir"] == Path(str(tmp_path))


def test_runner_importerror_maps_to_missing_dependencies(tmp_path: Path, monkeypatch):
    def _boom(project_dir: Path):
        raise ModuleNotFoundError("No module named 'librosa'")

    registry = PackRegistry()
    registry.engine = EngineRegistry()
    registry.engine.register_phase("needsdeps", _boom)
    monkeypatch.setattr(mcp_server, "discover_packs", lambda: registry)

    out = mcp_server.run_phase(str(tmp_path), "needsdeps")
    assert out["phase"] == "needsdeps"
    assert out["error"] == "missing_dependencies"
    assert "librosa" in out["detail"]
    assert "hint" in out


def test_runner_other_exception_maps_to_phase_failed(tmp_path: Path, monkeypatch):
    def _boom(project_dir: Path):
        raise ValueError("bad audio file")

    registry = PackRegistry()
    registry.engine = EngineRegistry()
    registry.engine.register_phase("breaks", _boom)
    monkeypatch.setattr(mcp_server, "discover_packs", lambda: registry)

    out = mcp_server.run_phase(str(tmp_path), "breaks")
    assert out == {
        "phase": "breaks",
        "error": "phase_failed",
        "detail": "bad audio file",
    }


def test_run_phase_tool_registered():
    assert callable(mcp_server.run_phase)
    assert mcp_server.run_phase_tool.__name__ == "run_phase_tool"
