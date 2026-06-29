from nexgen_pack_musicvideo import tempo
from nexgen_pack_musicvideo.tempo import TEMPO_BANDS, TempoBand, classify


def test_tempo_bands_non_empty():
    assert len(TEMPO_BANDS) >= 1
    assert all(isinstance(b, TempoBand) for b in TEMPO_BANDS)


def test_classify_returns_tempoband_with_sane_fields():
    band = classify(128.0)
    assert isinstance(band, TempoBand)
    assert band.label
    assert 0.0 < band.asl_min <= band.asl_target <= band.asl_max <= band.hard_cap
    assert band.bpm_min <= 128.0 < band.bpm_max


def test_classify_picks_uptempo_for_fast_bpm():
    assert classify(140.0).label == "uptempo_dance"


def test_classify_picks_downtempo_for_slow_bpm():
    band = classify(75.0)
    assert band.label == "downtempo_soul"
    assert band.bpm_min <= 75.0 < band.bpm_max


def test_classify_phrase_mode_relaxes_band():
    base = classify(128.0)
    phrase = classify(128.0, mode="phrase")
    assert phrase.hard_cap > base.hard_cap
    assert phrase.label.endswith("_phrase")


def test_asl_violation_smoke():
    band = classify(128.0)
    result = tempo.asl_violation([1.5, 1.5, 2.0], band)
    assert result["status"] == "ok"
    assert result["asl"] > 0.0
