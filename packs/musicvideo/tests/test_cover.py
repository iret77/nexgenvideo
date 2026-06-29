from pathlib import Path

from nexgen_pack_musicvideo.cover import (
    COVER_SCHEMA_VERSION,
    FORMAT_ASPECT,
    CoverClean,
    CoverManifest,
    CoverText,
    TextOverlay,
    load,
    save,
)


def test_schema_version():
    assert COVER_SCHEMA_VERSION == "cover/v2"


def test_format_aspect_map():
    assert FORMAT_ASPECT["square"] == "1:1"
    assert FORMAT_ASPECT["landscape"] == "16:9"
    assert FORMAT_ASPECT["portrait"] == "9:16"


def test_manifest_defaults_and_alias():
    m = CoverManifest(project="demo", generated="2026-06-29")
    assert m.schema_ == COVER_SCHEMA_VERSION
    assert m.format == "square"
    dumped = m.model_dump(by_alias=True)
    assert dumped["schema"] == COVER_SCHEMA_VERSION


def test_save_load_round_trip(tmp_path: Path):
    manifest = CoverManifest(
        project="demo",
        format="landscape",
        generated="2026-06-29",
        clean=CoverClean(
            path="cover/clean.png",
            prompt="moody album art",
            provider_prompt="moody album art, cinematic",
            model_id="gpt_image_2",
        ),
        text=CoverText(
            path="cover/text.png",
            overlay=TextOverlay(artist="Artist", title="Title"),
        ),
    )
    written = save(tmp_path, manifest)
    assert written == tmp_path / "cover" / "landscape.yaml"

    loaded = load(tmp_path, "landscape")
    assert loaded is not None
    assert loaded == manifest
