"""Gating tests for the audio-analysis DSP move.

These run in the FAST CI, where the ``audio`` extra is NOT installed (no
librosa/numpy/sklearn/…). They assert that nothing on the pack-load path pulls
a heavy dep: importing the pack, discovering it, and registering its phases all
stay green without the DSP stack. The DSP itself is exercised elsewhere, behind
the extra.

Do NOT import ``nexgen_pack_musicvideo.analysis.*`` here — those modules require
the heavy deps and would fail to import in this environment.
"""

from __future__ import annotations

import importlib

import pytest


def test_pack_imports_without_heavy_deps():
    """Importing the pack package + class must not pull librosa/numpy/etc."""
    import nexgen_pack_musicvideo
    from nexgen_pack_musicvideo import MusicvideoPack
    from nexgen_pack_musicvideo.pack import MusicvideoPack as PackFromModule

    assert nexgen_pack_musicvideo.MusicvideoPack is MusicvideoPack
    assert PackFromModule is MusicvideoPack


def test_analysis_subpackage_name_is_bare():
    """Importing the subpackage *name* must be free of heavy deps — the
    ``__init__`` carries no imports."""
    import nexgen_pack_musicvideo.analysis  # noqa: F401


def test_discovery_finds_musicvideo_with_analysis_phase():
    from nexgen_engine.pack import discover_packs

    reg = discover_packs()
    assert "musicvideo" in [p.name for p in reg.packs]
    assert "analysis" in reg.engine.phases


def test_analysis_phase_registered_without_running_dsp():
    """The phase runner is registered as a callable but never invoked here —
    invoking it would trigger the lazy heavy-dep import."""
    from nexgen_engine.pack import PackRegistry
    from nexgen_pack_musicvideo import MusicvideoPack

    reg = PackRegistry()
    reg.load(MusicvideoPack())
    runner = reg.engine.phases.get("analysis")
    assert callable(runner)


def test_pipeline_import_requires_heavy_dep():
    """Proves the DSP is genuinely isolated: importing the pipeline (which pulls
    librosa at module level) fails when the ``audio`` extra is absent."""
    with pytest.raises(ModuleNotFoundError):
        importlib.import_module("nexgen_pack_musicvideo.analysis.pipeline")
