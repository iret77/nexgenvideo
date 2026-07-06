#!/usr/bin/env bash
# Regenerate the NexGenEngineTests fixture project and the Python-oracle goldens.
#
# The Python engine (engine/) is the authority: this script scaffolds an
# authentic fixture project with the engine's own schema `save` functions, then
# dumps each `python -m nexgen_engine.read <kind>` document as a golden JSON.
# The Swift parity tests replay these against the Swift port.
#
# Requires `uv` (https://docs.astral.sh/uv/). Idempotent: it wipes and rebuilds
# both the Fixtures and Goldens trees. Run from anywhere.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE_DIR="$REPO_ROOT/engine"
TESTS_DIR="$REPO_ROOT/Tests/NexGenEngineTests"
FIXTURE_HOME="$TESTS_DIR/Fixtures/basic-project"
GOLDENS_DIR="$TESTS_DIR/Goldens/basic-project"
DATA_ROOT="$FIXTURE_HOME/_studio"

# The engine's runtime deps (pyproject) plus the local engine itself. `uv run
# --no-project` keeps this independent of any ambient venv; `--with <path>`
# builds and installs the engine from source.
UV=(uv run --no-project
    --with pydantic
    --with pyyaml
    --with mcp
    --with "$ENGINE_DIR"
    python)

echo "==> Wiping fixture + goldens"
rm -rf "$FIXTURE_HOME" "$GOLDENS_DIR"
mkdir -p "$(dirname "$FIXTURE_HOME")" "$GOLDENS_DIR"

echo "==> Scaffolding fixture project via the Python engine"
"${UV[@]}" - "$FIXTURE_HOME" <<'PY'
import sys
from datetime import date
from pathlib import Path

from nexgen_engine.core import layout as layout_mod
from nexgen_engine.core.modes import Mode
from nexgen_engine.brief import schema as brief_schema
from nexgen_engine.brief.schema import (
    Brief, Mission, AspectRatio, ConceptType, VisualMedium, FigurePresence, LyricsIntegration,
)
from nexgen_engine.ledger import schema as ledger_schema

home = Path(sys.argv[1])
data_root = layout_mod.init_project(home, "basic-project", Mode.BEAT, budget_eur=50.0)

# Minimal, schema-valid Brief (LIVE_ACTION_REALISTIC needs no visual_medium_notes).
brief = Brief(
    project="basic-project",
    generated=date(2026, 1, 1).isoformat(),
    mission=Mission.DEMO,
    target_platform="web",
    aspect_ratio=AspectRatio.LANDSCAPE_16_9,
    project_mode="beat",
    concept_type=ConceptType.ABSTRACT,
    visual_medium=VisualMedium.LIVE_ACTION_REALISTIC,
    figures=FigurePresence.NONE,
    lyrics_integration=LyricsIntegration.IGNORED,
)
brief_schema.save(data_root, brief)

# A single locked ledger attribute exercises the ledger read.
ledger_schema.set_attribute(
    str(data_root), "look", None, "palette",
    tag="warm amber and teal",
    directive="warm amber/teal grade",
    source="director note",
    locked=True,
)
print(f"scaffolded {data_root}")
PY

echo "==> Emitting goldens"
# `state/brief/ledger` need the project dir; `phases/router/contract` are projectless.
for kind in state phases brief ledger contract router; do
  case "$kind" in
    phases|router|contract) arg="" ;;
    *)                       arg="$DATA_ROOT" ;;
  esac
  out="$GOLDENS_DIR/$kind.json"
  # Pretty-print so the goldens diff cleanly in review; the reader still emits
  # compact JSON, we just reformat here.
  "${UV[@]}" -m nexgen_engine.read "$kind" $arg | "${UV[@]}" -m json.tool > "$out"
  echo "  wrote $out"
done

echo "==> Emitting prompt-builder golden vectors"
# The prompt layer (render/prompt/builder.py) has no filesystem fixture — its
# product is the emitted prompt string itself. This block imports the real
# Python builders and dumps a JSON of test vectors (provider builder ×
# representative payload → expectedPrompt). The Swift PromptGoldenTests replay
# each: rebuild the payload, assert Swift output == expectedPrompt byte-exact.
#
# Payloads are derived from engine/tests/test_prompt.py + test_ledger_prompt.py
# so they exercise the same behaviors those tests assert, plus the full builder
# matrix (all image providers, seedance's 3 sub-modes, slop/negation/cartoon/
# pacing/multi-ref/@Image-tag/directive cases).
PROMPT_VECTORS_OUT="$TESTS_DIR/Goldens/prompt-vectors.json"
"${UV[@]}" - "$PROMPT_VECTORS_OUT" <<'PY'
import json
import sys

from nexgen_engine.render.prompt.builder import (
    PromptPayload,
    ReferenceTag,
    build_image_prompt,
    build_video_prompt,
    build_for_nano_banana,
    build_for_gpt_image_2,
    build_for_imagen,
    build_for_runway_image,
    build_for_seedance_2,
)

# --- Reusable payload fragments (mirrors the Python test cases) -------------

# From test_prompt.py::test_build_image_prompt_strips_slop_and_frames_positively
DETECTIVE = dict(
    subject="a weathered detective standing in a doorway, arrested mid-step",
    setting="a dim office, blinds half-drawn",
    camera="static eye-level camera",
    light="warm morning light from the left, long soft shadow",
    style="muted noir illustration",
    negatives=["no text"],
)

vectors = []


def payload_fields(p: PromptPayload) -> dict:
    """Serialize exactly the PromptPayload fields the Swift side reconstructs."""
    return {
        "subject": p.subject,
        "setting": p.setting,
        "composition": p.composition,
        "camera": p.camera,
        "style": p.style,
        "light": p.light,
        "negatives": list(p.negatives),
        "sheetView": p.sheet_view,
        "isStartFrame": p.is_start_frame,
        "durationS": p.duration_s,
        "aspectRatio": p.aspect_ratio,
        "nShots": p.n_shots,
        "multiRefHints": list(p.multi_ref_hints),
        "directives": list(p.directives),
    }


def ref_tags_json(tags):
    if tags is None:
        return None
    return [{"role": t.role, "bibleId": t.bible_id, "hint": t.hint} for t in tags]


def add_image(case_name, model_id, payload, sheet_kind="character"):
    vectors.append({
        "caseName": case_name,
        "builder": "image",
        "modelId": model_id,
        "sheetKind": sheet_kind,
        "payload": payload_fields(payload),
        "expectedPrompt": build_image_prompt(model_id, payload, sheet_kind=sheet_kind),
    })


def add_direct(case_name, builder_name, fn, payload, sheet_kind="character"):
    vectors.append({
        "caseName": case_name,
        "builder": builder_name,
        "sheetKind": sheet_kind,
        "payload": payload_fields(payload),
        "expectedPrompt": fn(payload, sheet_kind=sheet_kind),
    })


def add_video(case_name, model_id, payload, *,
              has_start_image=False, has_end_image=False,
              is_pacing_arm=False, reference_tags=None):
    vectors.append({
        "caseName": case_name,
        "builder": "video",
        "modelId": model_id,
        "hasStartImage": has_start_image,
        "hasEndImage": has_end_image,
        "isPacingArm": is_pacing_arm,
        "referenceTags": ref_tags_json(reference_tags),
        "payload": payload_fields(payload),
        "expectedPrompt": build_video_prompt(
            model_id, payload,
            has_start_image=has_start_image,
            has_end_image=has_end_image,
            is_pacing_arm=is_pacing_arm,
            reference_tags=reference_tags,
        ),
    })


def add_seedance(case_name, payload, *, has_start_image=False, has_end_image=False,
                 is_pacing_arm=False, reference_tags=None):
    vectors.append({
        "caseName": case_name,
        "builder": "seedance_2",
        "hasStartImage": has_start_image,
        "hasEndImage": has_end_image,
        "isPacingArm": is_pacing_arm,
        "referenceTags": ref_tags_json(reference_tags),
        "payload": payload_fields(payload),
        "expectedPrompt": build_for_seedance_2(
            payload,
            has_start_image=has_start_image,
            has_end_image=has_end_image,
            is_pacing_arm=is_pacing_arm,
            reference_tags=reference_tags,
        ),
    })


# ===== IMAGE — dispatcher across every provider =============================

# Minimal: only a subject.
minimal = PromptPayload(subject="a lone lighthouse on a cliff at dawn")
add_image("image_minimal_nano_banana", "google:nano-banana", minimal)
add_image("image_minimal_gpt_image_2", "openai:gpt-image-2", minimal)
add_image("image_minimal_imagen", "google:imagen-4-ultra", minimal)
add_image("image_minimal_runway", "runway:gen4-image", minimal)
add_image("image_minimal_fallback_unknown_provider", "flux:dev", minimal)

# Full-featured detective (from test_prompt.py), each provider.
full = PromptPayload(**DETECTIVE)
add_image("image_full_nano_banana", "google:nano-banana", full)
add_image("image_full_gpt_image_2", "openai:gpt-image-2", full)
add_image("image_full_imagen", "google:imagen-4-ultra", full)
add_image("image_full_runway", "runway:gen4-image", full)

# Sheet mode — character views.
add_image(
    "image_sheet_front_nano_banana", "google:nano-banana",
    PromptPayload(subject="Alex, a young teacher", sheet_view="front"),
)
add_image(
    "image_sheet_side_gpt_image_2", "openai:gpt-image-2",
    PromptPayload(subject="Alex, a young teacher", sheet_view="side"),
)
add_image(
    "image_sheet_expression_gpt_image_2", "openai:gpt-image-2",
    PromptPayload(subject="Alex, a young teacher", sheet_view="expression_worried"),
)
# Sheet mode — location + prop kinds (exercise sheet_kind dispatch).
add_direct(
    "image_sheet_location_wide_nano_banana", "nano_banana", build_for_nano_banana,
    PromptPayload(subject="the empty classroom", sheet_view="wide"),
    sheet_kind="location",
)
add_direct(
    "image_sheet_location_dotted_variant_imagen", "imagen", build_for_imagen,
    PromptPayload(subject="the empty classroom", sheet_view="wide.morning"),
    sheet_kind="location",
)
add_direct(
    "image_sheet_prop_open_gpt_image_2", "gpt_image_2", build_for_gpt_image_2,
    PromptPayload(subject="a leather satchel", sheet_view="open"),
    sheet_kind="prop",
)
add_direct(
    "image_sheet_prop_freeform_runway", "runway_image", build_for_runway_image,
    PromptPayload(subject="a leather satchel", sheet_view="half_zipped"),
    sheet_kind="prop",
)

# Multi-ref with @Image tags in hints — indexed refs + single-output directive.
multiref = PromptPayload(
    subject="@Image1 stands where @Image2 opens onto the courtyard",
    setting="school courtyard at midday",
    style="flat 2D illustration",
    multi_ref_hints=["location entrance angle", "wide courtyard reference"],
)
add_image("image_multiref_nano_banana", "google:nano-banana", multiref)
add_image("image_multiref_gpt_image_2", "openai:gpt-image-2", multiref)

# Slop-laden input — vague praise + tech lingo + meta + numbered labels.
sloppy = PromptPayload(
    subject=(
        "1. MOTIV: a stunning cinematic 8k breathtaking hero shot, 50mm f/2.8 "
        "ISO 800 24fps. THIS IS THE FIRST FRAME of the action."
    ),
    setting="an epic gorgeous vista",
    camera="professional award-winning camera move, very fast dolly",
    light="beautiful golden hour light",
    style="ultra-detailed masterpiece style",
)
add_image("image_sloplaeden_nano_banana", "google:nano-banana", sloppy)
add_image("image_sloplaeden_gpt_image_2", "openai:gpt-image-2", sloppy)

# Negation input — several inline negatives to positive framing + dedupe.
negation = PromptPayload(
    subject="an empty roadside diner",
    setting="dusty highway, no cars, no people",
    negatives=["no text", "no watermarks", "no logos", "no text"],
)
add_image("image_negation_nano_banana", "google:nano-banana", negation)
add_image("image_negation_imagen", "google:imagen-4-ultra", negation)

# Directive carry-through (from test_ledger_prompt.py::test_builders_carry_directives).
directive_payload = PromptPayload(
    subject="Mara stands at the rooftop edge",
    directives=[
        "Muted teal-and-rust palette",
        "Heavy 16mm grain",
        "Mara wears her faded red canvas jacket",
        "The dagger stays sheathed",
        "Slow, deliberate movement",
    ],
)
add_image("image_directives_nano_banana", "google:nano-banana", directive_payload)

# ===== VIDEO — Seedance, all three sub-modes ================================

# t2v (text-to-video): full 6-step, no anchors/refs.
t2v = PromptPayload(
    subject="a woman in a red coat walks briskly across a plaza",
    composition="medium-wide shot, subject slightly left of center",
    setting="a rain-slicked city plaza at dusk",
    camera="slow dolly-back following the subject",
    light="soft overcast daylight with wet reflections",
    style="grounded live-action look",
    duration_s=6.0,
    aspect_ratio="16:9",
)
add_video("video_t2v_seedance", "runway:seedance-2", t2v)
add_seedance("video_t2v_seedance_direct", t2v)

# t2v multi-shot header (n_shots > 1).
t2v_multi = PromptPayload(
    subject="a cyclist coasts down a hill then brakes at the corner",
    setting="a quiet suburban street",
    camera="locked-off wide, then a short push-in",
    light="late afternoon sun",
    duration_s=8.0,
    aspect_ratio="9:16",
    n_shots=2,
)
add_seedance("video_t2v_multishot_seedance", t2v_multi)

# i2v (image-to-video): start image only.
i2v_start = PromptPayload(
    subject="the figure turns to look over their shoulder",
    camera="slow push-in",
    light="warm practical lamplight",
    duration_s=5.0,
    aspect_ratio="16:9",
)
add_seedance("video_i2v_start_only_seedance", i2v_start, has_start_image=True)

# i2v: start + end.
i2v_start_end = PromptPayload(
    subject="the door swings from closed to fully open",
    camera="static locked-off",
    light="cool morning daylight",
    duration_s=4.0,
    aspect_ratio="1:1",
)
add_seedance("video_i2v_start_end_seedance", i2v_start_end,
             has_start_image=True, has_end_image=True)

# reference mode: single character tag, subject already tagged.
ref_tagged = PromptPayload(
    subject="@Image1 waves while the camera holds",
    light="soft overcast daylight",
    duration_s=6.0,
    aspect_ratio="16:9",
)
add_video(
    "video_reference_tagged_subject_seedance", "runway:seedance-2", ref_tagged,
    reference_tags=[ReferenceTag(role="character", bible_id="hero", hint="the hero")],
)

# reference mode: multiple tags, untagged subject → first-char heuristic + 2nd tier.
ref_untagged = PromptPayload(
    subject="the mouse waves while the cat watches from the doorway",
    setting="a cozy studio kitchen",
    style="Studio Ghibli soft illustration",
    light="warm morning light",
    duration_s=6.0,
    aspect_ratio="16:9",
)
add_seedance(
    "video_reference_untagged_multiref_seedance", ref_untagged,
    reference_tags=[
        ReferenceTag(role="character", bible_id="ai_cat", hint="AI Cat"),
        ReferenceTag(role="character", bible_id="claude_mouse", hint="Claude Mouse"),
        ReferenceTag(role="location", bible_id="kitchen", hint="the studio kitchen"),
    ],
)

# reference mode: only location/prop tags, no character → action without @ binding.
ref_no_char = PromptPayload(
    subject="wind stirs the curtains and papers scatter",
    duration_s=5.0,
    aspect_ratio="16:9",
)
add_seedance(
    "video_reference_no_character_seedance", ref_no_char,
    reference_tags=[
        ReferenceTag(role="location", bible_id="office", hint="the empty office"),
        ReferenceTag(role="prop", bible_id="desk", hint="the oak desk"),
    ],
)

# Cartoon style → cartoon shadow constraint appended.
cartoon = PromptPayload(
    subject="two characters stand side by side in the desert",
    setting="a wide desert at sunset",
    camera="slow pan across the dunes",
    light="warm low sun",
    style="flat 2D Hanna-Barbera animation style",
    duration_s=6.0,
    aspect_ratio="16:9",
)
add_seedance("video_cartoon_shadow_seedance", cartoon)

# Character-detection constraints (subject mentions a person).
character_video = PromptPayload(
    subject="a dancer spins across the stage",
    camera="orbiting move around the dancer",
    light="a single hard key light",
    duration_s=5.0,
    aspect_ratio="16:9",
)
add_seedance("video_character_constraints_seedance", character_video)

# Pacing arm: idle-bracketing choreography (is_pacing_arm=True).
pacing = PromptPayload(
    subject="a barista slides a cup across the counter",
    setting="a small cafe",
    camera="static medium shot",
    light="warm interior light",
    duration_s=7.0,
    aspect_ratio="16:9",
)
add_seedance("video_pacing_arm_idle_bracketing_seedance", pacing, is_pacing_arm=True)

# Short shot (<5s), not pacing-arm → no pacing block.
short = PromptPayload(
    subject="a hand flicks a light switch",
    camera="tight static shot",
    light="fluorescent overhead light",
    duration_s=3.0,
    aspect_ratio="16:9",
)
add_seedance("video_short_no_pacing_seedance", short)

# Video with directives appended.
video_directives = PromptPayload(
    subject="Mara scans the horizon from the rooftop",
    camera="slow pan",
    light="overcast daylight",
    duration_s=6.0,
    aspect_ratio="16:9",
    directives=["Heavy 16mm grain", "Mara wears her faded red canvas jacket"],
)
add_seedance("video_directives_seedance", video_directives)

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"vectors": vectors}, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"wrote {len(vectors)} prompt vectors → {sys.argv[1]}")
PY

echo "==> Done. Fixture: $FIXTURE_HOME  Goldens: $GOLDENS_DIR"
