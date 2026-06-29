from nexgen_pack_musicvideo import analysis_schema
from nexgen_pack_musicvideo.analysis_schema import ANALYSIS_SCHEMA_VERSION, Analysis


def test_schema_version():
    assert ANALYSIS_SCHEMA_VERSION == "analysis/v2"


def test_top_level_model_exists():
    assert hasattr(analysis_schema, "Analysis")
    assert Analysis.__name__ == "Analysis"
