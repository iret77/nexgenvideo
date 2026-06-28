from dataclasses import dataclass

from nexgen_engine.pack import (
    DurationBand,
    DurationPolicy,
    EngineRegistry,
    Pack,
    PackRegistry,
)


class _MusicDurationPolicy:
    def band_for(self, mode: str, context: dict) -> DurationBand:
        bpm = context.get("bpm", 120)
        beat = 60.0 / bpm
        return DurationBand(label=mode, min_s=beat, max_s=4 * beat)


@dataclass
class _MusicPack:
    name: str = "musicvideo"
    version: str = "0.0.1"

    def register(self, registry: EngineRegistry) -> None:
        registry.register_phase("analysis", lambda project: {"phase": "analysis"})
        registry.register_sanity_check("tempo", lambda shotlist: [])
        registry.register_duration_policy(_MusicDurationPolicy())
        registry.register_library("patterns", {"genres": ["pop", "rock"]})


def test_pack_registers_into_engine():
    reg = PackRegistry()
    reg.load(_MusicPack())

    assert "analysis" in reg.engine.phases
    assert "tempo" in reg.engine.sanity_checks
    assert reg.engine.duration_policy is not None
    assert reg.engine.libraries["patterns"]["genres"] == ["pop", "rock"]


def test_duration_policy_is_pack_supplied():
    reg = PackRegistry()
    reg.load(_MusicPack())
    band = reg.engine.duration_policy.band_for("phrase", {"bpm": 120})
    assert band.min_s == 0.5  # 60 / 120
    assert band.max_s == 2.0  # 4 * 0.5


def test_protocols_are_structurally_satisfied():
    assert isinstance(_MusicPack(), Pack)
    assert isinstance(_MusicDurationPolicy(), DurationPolicy)
