"""The musicvideo pack — registers music-specific behavior into the Generic Engine."""

from __future__ import annotations

from nexgen_engine.pack import DurationBand, EngineRegistry

#: Music shot-duration bands per mode. These were the engine-side MODE_DURATION_RANGES;
#: supplied by the pack now, so the engine's Shot/sanity logic stays format-neutral.
_DURATION_BANDS: dict[str, tuple[float, float]] = {
    "beat": (4.0, 15.0),
    "phrase": (4.0, 15.0),
    "section": (6.0, 60.0),
    "multicam": (30.0, 600.0),
}


class MusicDurationPolicy:
    def band_for(self, mode: object, context: dict) -> DurationBand:
        key = getattr(mode, "value", mode)
        lo, hi = _DURATION_BANDS.get(str(key), (4.0, 15.0))
        return DurationBand(label=str(key), min_s=lo, max_s=hi)


def _tempo_check(ctx: object) -> list:
    """Music tempo/pacing validation. The real logic lands here once the audio
    analysis phase moves into the pack (it needs BPM). Placeholder: no findings yet."""
    return []


def _analysis_phase(project_dir: object) -> object:
    """Audio analysis (beat/downbeat/stems/chords). Ports from musicvideo next."""
    raise NotImplementedError("music analysis phase not yet ported")


class MusicvideoPack:
    name = "musicvideo"
    version = "0.0.1"

    def register(self, registry: EngineRegistry) -> None:
        registry.register_duration_policy(MusicDurationPolicy())
        registry.register_project_dirs(["audio", "lyrics", "analysis"])
        registry.register_sanity_check("tempo", _tempo_check)
        registry.register_phase("analysis", _analysis_phase)
