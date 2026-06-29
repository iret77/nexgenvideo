"""Prompt-composition layer — builder + linters (engine-side)."""

from __future__ import annotations

from pathlib import Path

from nexgen_engine.render.prompt.builder import (
    PromptPayload,
    ReferenceTag,
    build_image_prompt,
    build_video_prompt,
)
from nexgen_engine.render.prompt.compliance_linter import lint_prompt_against_shot
from nexgen_engine.render.prompt.content_block_linter import (
    lint_provider_prompt,
    lint_shot_for_multi_character_block,
)
from nexgen_engine.render.prompt.linter import has_blocking, lint_prompt

_PROMPT_DIR = Path(__file__).parent.parent / "nexgen_engine" / "render" / "prompt"


def test_no_musicvideo_token_in_any_module() -> None:
    for src in _PROMPT_DIR.glob("*.py"):
        assert "musicvideo" not in src.read_text(encoding="utf-8"), src.name


def test_build_image_prompt_strips_slop_and_frames_positively() -> None:
    payload = PromptPayload(
        subject="a weathered detective standing in a doorway, arrested mid-step",
        setting="a dim office, blinds half-drawn",
        camera="static eye-level camera",
        light="warm morning light from the left, long soft shadow",
        style="muted noir illustration",
        negatives=["no text"],
    )
    out = build_image_prompt("openai:gpt-image-2", payload)
    assert isinstance(out, str) and out.strip()
    # negative converted to positive framing, raw negation gone
    assert "clean untyped surfaces" in out
    assert "no text" not in out.lower()


def test_build_video_prompt_emits_reference_tags() -> None:
    payload = PromptPayload(
        subject="@Image1 waves while the camera holds",
        light="soft overcast daylight",
        duration_s=6.0,
        aspect_ratio="16:9",
    )
    out = build_video_prompt(
        "runway:seedance-2",
        payload,
        reference_tags=[ReferenceTag(role="character", bible_id="hero", hint="the hero")],
    )
    assert "@Image1" in out
    assert "Total: 6s" in out


def test_lint_prompt_flags_short_prompt_as_blocking() -> None:
    findings = lint_prompt("tiny")
    assert has_blocking(findings)
    assert any(f.code == "PROMPT_TOO_SHORT" for f in findings)


def test_lint_prompt_clean_on_well_formed_prompt() -> None:
    good = (
        "a weathered detective standing in a doorway. a dim office, blinds "
        "half-drawn. static eye-level camera. warm morning light from the "
        "left, long soft shadow. muted noir illustration."
    )
    findings = lint_prompt(good)
    assert not has_blocking(findings)


def test_content_block_linter_flags_violence_token() -> None:
    findings = lint_provider_prompt("a figure draws a gun in the alley")
    assert any(f.code == "BLOCKING_RISK_VIOLENCE" for f in findings)


def test_multi_character_block_uses_duck_typed_shot_fields() -> None:
    findings = lint_shot_for_multi_character_block(
        character_refs=["hero", "rival"],
        framing="ms",
        visual_medium="2d_animation",
    )
    assert any(f.code == "BLOCKING_RISK_MULTI_CHARACTER" for f in findings)


def test_compliance_linter_detects_camera_height_mismatch() -> None:
    class _Cam:
        height = "eye_level"

    class _Shot:
        framing = "ms"
        camera_setup = _Cam()
        character_blocking: list = []
        notes = ""

    findings = lint_prompt_against_shot(
        "aerial view of the rooftop", _Shot()
    )
    assert any(f.code == "CAMERA_HEIGHT_MISMATCH" for f in findings)
