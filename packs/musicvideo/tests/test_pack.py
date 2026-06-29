from nexgen_engine.pack import Pack, PackRegistry
from nexgen_pack_musicvideo import MusicvideoPack
from nexgen_pack_musicvideo.pack import MusicDurationPolicy


def test_pack_registers_music_behavior():
    reg = PackRegistry()
    reg.load(MusicvideoPack())
    assert reg.engine.duration_policy is not None
    assert "audio" in reg.engine.project_dirs
    assert "analysis" in reg.engine.project_dirs
    assert "tempo" in reg.engine.sanity_checks
    assert "analysis" in reg.engine.phases


def test_music_duration_bands():
    policy = MusicDurationPolicy()
    band = policy.band_for("section", {})
    assert (band.min_s, band.max_s) == (6.0, 60.0)


def test_pack_satisfies_contract():
    assert isinstance(MusicvideoPack(), Pack)
