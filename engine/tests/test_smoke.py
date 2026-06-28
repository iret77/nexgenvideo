"""Smoke tests for the first engine vertical slice (Tier 1A leaf modules).

These prove the relocated modules import cleanly under the `nexgen_engine`
package and that a few pure functions behave. The entangled music-coupled
tests stay in the musicvideo repo until their dependencies are relocated.
"""


def test_engine_core_imports():
    from nexgen_engine.core import paths, schema_versions, aspect, models  # noqa: F401
    from nexgen_engine.treatment import schema  # noqa: F401


def test_known_constants():
    from nexgen_engine.core import paths
    from nexgen_engine.treatment import schema

    assert paths.STUDIO_DIRNAME == "_studio"
    assert schema.TREATMENT_SCHEMA_VERSION == "treatment/v1"


def test_aspect_pure_functions():
    from nexgen_engine.core import aspect

    assert abs(aspect.aspect_float("16:9") - (16 / 9)) < 1e-6
    assert aspect.parse_aspect_freeform("16:9") == "16:9"
