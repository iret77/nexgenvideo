"""Seam 1: the engine keeps a generic `Mode`; the per-mode duration bands are
supplied by a pack via `DurationPolicy`. Proves project.py is generic once Mode
lives in the engine, and that the music duration data is fully pack-side."""

from nexgen_engine.core import project as project_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.pack import DurationBand, EngineRegistry, PackRegistry

# Formerly musicvideo `shotlist.schema.MODE_DURATION_RANGES` — now pack data.
_MUSIC_BANDS = {
    Mode.BEAT: (4.0, 15.0),
    Mode.PHRASE: (4.0, 15.0),
    Mode.SECTION: (6.0, 60.0),
    Mode.MULTICAM: (30.0, 600.0),
}


class _MusicDurationPolicy:
    def band_for(self, mode: str, context: dict) -> DurationBand:
        lo, hi = _MUSIC_BANDS[Mode(mode)]
        return DurationBand(label=str(mode), min_s=lo, max_s=hi)


class _MusicPack:
    name = "musicvideo"
    version = "0.0.1"

    def register(self, registry: EngineRegistry) -> None:
        registry.register_duration_policy(_MusicDurationPolicy())


def test_mode_is_generic_and_complete():
    assert [m.value for m in Mode] == ["beat", "phrase", "section", "multicam"]


def test_duration_bands_are_pack_supplied():
    reg = PackRegistry()
    reg.load(_MusicPack())
    band = reg.engine.duration_policy.band_for(Mode.SECTION, {})
    assert (band.min_s, band.max_s) == (6.0, 60.0)


def test_project_meta_is_generic():
    meta = project_mod.ProjectMeta(project="demo", mode=Mode.BEAT)
    assert meta.mode is Mode.BEAT
    assert meta.budget_eur == 50.0
