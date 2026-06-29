from nexgen_engine.brief import schema as brief_schema


def test_brief_schema_version():
    assert brief_schema.BRIEF_SCHEMA_VERSION == "brief/v1"


def test_brief_core_enums_present():
    for name in ("Mission", "ConceptType", "AspectRatio", "VisualMedium"):
        assert hasattr(brief_schema, name)
