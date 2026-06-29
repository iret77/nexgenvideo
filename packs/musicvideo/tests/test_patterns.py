from nexgen_pack_musicvideo import patterns, patterns_schema
from nexgen_pack_musicvideo.patterns import (
    MoodBand,
    Pattern,
    TempoBand,
    load_all_patterns,
    score_patterns,
    suggest_similar,
)


def test_moodband_values():
    assert MoodBand.CINEMATIC.value == "cinematic"
    assert MoodBand.HIGH_ENERGY.value == "high_energy"


def test_tempoband_values():
    assert TempoBand.SLOW.value == "slow"
    assert TempoBand.FAST.value == "fast"


def test_tempo_band_thresholds():
    assert patterns_schema._tempo_band(70) is TempoBand.SLOW
    assert patterns_schema._tempo_band(95) is TempoBand.MEDIUM
    assert patterns_schema._tempo_band(120) is TempoBand.UPTEMPO
    assert patterns_schema._tempo_band(160) is TempoBand.FAST


def test_top_level_classes_exist():
    assert hasattr(patterns_schema, "Pattern")
    assert Pattern.__name__ == "Pattern"
    for name in ("PatternScore", "PatternTriggers", "FramingMix", "AslRange"):
        assert hasattr(patterns_schema, name)


def test_library_loads_and_validates():
    library = load_all_patterns()
    assert len(library) >= 1
    assert all(isinstance(p, Pattern) for p in library)


def test_score_and_similarity_smoke():
    scored = score_patterns(max_results=3, min_score=None)
    assert len(scored) >= 1
    anchor_id = scored[0][0].id
    neighbours = suggest_similar(anchor_id, top=3)
    assert all(0.0 <= s <= 1.0 for _, s in neighbours)


def test_public_api_reexports():
    for name in ("suggest_patterns", "load_pattern", "infer_mood", "similarity"):
        assert hasattr(patterns, name)
