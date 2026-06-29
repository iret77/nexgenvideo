"""Tests for the relocated display formatters under `nexgen_engine.show`.

Lightweight: prove the module imports cleanly, the key formatter functions
exist, the pure helpers compute, and one path-driven formatter handles a
missing artifact gracefully (no heavy model construction needed).
"""

from pathlib import Path


def test_show_module_imports():
    from nexgen_engine.show import formatters  # noqa: F401


def test_key_formatters_exist():
    from nexgen_engine.show import formatters

    for name in (
        "show_brief",
        "show_treatment",
        "show_bible",
        "show_shotlist",
        "show_storyboard",
        "show_renders",
    ):
        assert hasattr(formatters, name), name


def test_pure_helpers():
    from nexgen_engine.show import formatters

    assert formatters._mm_ss(0) == "0:00"
    assert formatters._mm_ss(75) == "1:15"
    assert formatters._shorten("hello", 80) == "hello"
    assert formatters._shorten("x" * 100, 10).endswith("…")


def test_show_bible_missing_artifact(tmp_path: Path):
    from nexgen_engine.show import formatters

    out = formatters.show_bible(tmp_path)
    assert isinstance(out, str)
    assert "bible.yaml" in out
