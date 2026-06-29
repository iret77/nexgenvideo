import nexgen_engine.core.modes as core_modes
from nexgen_engine.shotlist import schema


def test_shotlist_module_imports():
    assert schema is not None


def test_shotlist_schema_version():
    assert schema.SCHEMA_VERSION == "shotlist/v3"


def test_mode_is_rewired_to_core():
    # Proves the local Mode enum was removed and the import points at the canonical core Mode.
    assert schema.Mode is core_modes.Mode


def test_mode_duration_ranges_is_gone():
    # The per-mode duration data moved out of the format-neutral schema (now a DurationPolicy concern).
    assert not hasattr(schema, "MODE_DURATION_RANGES")


def test_shotlist_round_trip():
    shot = schema.Shot(
        id="s001",
        section="verse",
        time_start=0.0,
        time_end=4.0,
        duration_s=4.0,
        type=schema.ShotType.PERFORMANCE,
        description="d",
        visual_prompt="p",
        mood="m",
    )
    song = schema.Song(
        title="t",
        audio_path="a.wav",
        analysis_path="an.json",
        bpm=120.0,
        duration_s=4.0,
    )
    sl = schema.Shotlist(
        schema=schema.SCHEMA_VERSION,
        mode=core_modes.Mode.SECTION,
        project="proj",
        song=song,
        generated="2026-01-01",
        generator="test",
        shots=[shot],
    )
    dumped = sl.model_dump(by_alias=True)
    again = schema.Shotlist.model_validate(dumped)
    assert again.shots[0].id == "s001"
    assert again.mode is core_modes.Mode.SECTION
