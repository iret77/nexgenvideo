#!/usr/bin/env python3
"""Build the checked-in, offline model-capability corpus and coverage report."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import quote


ROOT = Path(__file__).resolve().parents[1]
RESOURCE_DIR = ROOT / "Sources/NexGenVideo/Resources/ModelCapabilities"
CORPUS_PATH = RESOURCE_DIR / "model-capability-corpus-v1.json"
REPORT_PATH = ROOT / "docs/model-capability-coverage.md"
OBSERVED_AT = "2026-08-31"
CORPUS_SCHEMA = "model-capability-corpus/v1"
KB_SCHEMA = "model-capability-kb/v1"
STALE_AFTER_DAYS = 120


COMMON_STRING_FIELDS = [
    "common.modes",
    "common.input_kinds",
    "common.output_kinds",
    "common.resolutions",
    "common.aspect_ratios",
    "common.known_exclusivities",
]
COMMON_INTEGER_FIELDS = ["common.prompt_characters"]
VIDEO_INTEGER_FIELDS = [
    "video.visible_characters",
    "video.reference_images",
    "video.reference_videos",
    "video.reference_audios",
    "video.total_references",
]
VIDEO_DECIMAL_FIELDS = [
    "video.combined_video_reference_seconds",
    "video.combined_audio_reference_seconds",
    "video.duration_minimum_seconds",
    "video.duration_maximum_seconds",
]
VIDEO_BOOLEAN_FIELDS = [
    "video.first_frame",
    "video.last_frame",
    "video.source_video",
    "video.edit",
    "video.extend",
    "video.duration_automatic",
    "video.native_audio",
    "video.lip_sync",
]
VIDEO_INTEGER_LIST_FIELDS = ["video.duration_values_seconds", "video.fps_values"]
IMAGE_INTEGER_FIELDS = [
    "image.visible_characters",
    "image.references",
    "image.outputs_per_request",
]
IMAGE_BOOLEAN_FIELDS = [
    "image.mask",
    "image.inpaint",
    "image.outpaint",
    "image.edit",
    "image.identity",
]
IMAGE_STRING_FIELDS = ["image.reference_roles"]
AUDIO_DECIMAL_FIELDS = [
    "audio.duration_minimum_seconds",
    "audio.duration_maximum_seconds",
]
AUDIO_BOOLEAN_FIELDS = [
    "audio.lyrics",
    "audio.vocals",
    "audio.reference_audio",
    "audio.continue",
    "audio.remix",
    "audio.stems",
    "audio.tempo_control",
    "audio.key_control",
]
AUDIO_STRING_FIELDS = ["audio.languages"]


FIELD_TYPES: dict[str, str] = {}
for field_id in COMMON_STRING_FIELDS + IMAGE_STRING_FIELDS + AUDIO_STRING_FIELDS:
    FIELD_TYPES[field_id] = "strings"
for field_id in COMMON_INTEGER_FIELDS + VIDEO_INTEGER_FIELDS + IMAGE_INTEGER_FIELDS:
    FIELD_TYPES[field_id] = "integers"
for field_id in VIDEO_DECIMAL_FIELDS + AUDIO_DECIMAL_FIELDS:
    FIELD_TYPES[field_id] = "decimals"
for field_id in VIDEO_BOOLEAN_FIELDS + IMAGE_BOOLEAN_FIELDS + AUDIO_BOOLEAN_FIELDS:
    FIELD_TYPES[field_id] = "booleans"
for field_id in VIDEO_INTEGER_LIST_FIELDS:
    FIELD_TYPES[field_id] = "integer_lists"


REQUIRED_BY_MODALITY = {
    "video": set(
        COMMON_STRING_FIELDS
        + COMMON_INTEGER_FIELDS
        + VIDEO_INTEGER_FIELDS
        + VIDEO_DECIMAL_FIELDS
        + VIDEO_BOOLEAN_FIELDS
        + VIDEO_INTEGER_LIST_FIELDS
    ),
    "image": set(
        COMMON_STRING_FIELDS
        + COMMON_INTEGER_FIELDS
        + IMAGE_INTEGER_FIELDS
        + IMAGE_BOOLEAN_FIELDS
        + IMAGE_STRING_FIELDS
    ),
    "audio": set(
        COMMON_STRING_FIELDS
        + COMMON_INTEGER_FIELDS
        + AUDIO_DECIMAL_FIELDS
        + AUDIO_BOOLEAN_FIELDS
        + AUDIO_STRING_FIELDS
    ),
    "music": set(
        COMMON_STRING_FIELDS
        + COMMON_INTEGER_FIELDS
        + AUDIO_DECIMAL_FIELDS
        + AUDIO_BOOLEAN_FIELDS
        + AUDIO_STRING_FIELDS
    ),
}


@dataclass(frozen=True, order=True)
class Identity:
    family: str
    variant: str
    version: str
    modality: str

    def json(self) -> dict[str, str]:
        return {
            "family_id": self.family,
            "variant_id": self.variant,
            "version_id": self.version,
            "modality": self.modality,
        }

    @property
    def key(self) -> str:
        return f"{self.family}/{self.variant}/{self.version}/{self.modality}"


@dataclass
class ProfileSpec:
    identity: Identity
    source_ids: set[str] = field(default_factory=set)
    fields: dict[str, dict[str, Any]] = field(default_factory=dict)
    gaps: dict[str, str] = field(default_factory=dict)
    predecessor: str | None = None


SOURCES: dict[str, dict[str, Any]] = {
    "fal-model-api": {
        "title": "fal Model Search API and endpoint OpenAPI schemas",
        "url": "https://fal.ai/docs/platform-apis/v1/models",
        "observed_at": OBSERVED_AT,
        "kind": "provider_schema",
        "confidence": 0.98,
        "primary": True,
        "scope": "Free endpoint-id and OpenAPI lookups for the shipped fal registry plus MiniMax H3; no generation calls.",
    },
    "fal-seedance-2.5": {
        "title": "fal Seedance 2.5 endpoint documentation",
        "url": "https://fal.ai/models/bytedance/seedance-2.5/reference-to-video",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.96,
        "primary": True,
        "scope": "Text, image and reference modes; reference counts and duration/resolution contracts.",
    },
    "fal-seedance-2.5-guide": {
        "title": "fal Seedance 2.5 production guidance",
        "url": "https://fal.ai/learn/devs/how-to-use-seedance-2-5",
        "observed_at": OBSERVED_AT,
        "kind": "empirical",
        "confidence": 0.82,
        "primary": True,
        "scope": "Provider-published reliable subject/reference guidance, kept separate from hard API limits.",
    },
    "minimax-h3": {
        "title": "MiniMax H3 open model specification",
        "url": "https://www.minimax.io/news/minimax-h3-open-source",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.99,
        "primary": True,
        "scope": "Creator specification for FL2VA and Ref2VA, durations, FPS, audio and multimodal references.",
    },
    "fal-minimax-h3": {
        "title": "fal MiniMax H3 live endpoint schema",
        "url": "https://api.fal.ai/v1/models?endpoint_id=minimax%2Fh3%2Freference-to-video&expand=openapi-3.0",
        "observed_at": OBSERVED_AT,
        "kind": "provider_schema",
        "confidence": 0.99,
        "primary": True,
        "scope": "Free live OpenAPI lookup; no generation call.",
    },
    "fal-minimax-h3-product": {
        "title": "fal MiniMax H3 endpoint documentation",
        "url": "https://fal.ai/models/minimax/h3/reference-to-video",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.94,
        "primary": True,
        "scope": "Provider-published prompt guidance for MiniMax H3 reference-to-video.",
    },
    "runway-models": {
        "title": "Runway Dev available models",
        "url": "https://docs.dev.runwayml.com/guides/models/",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.98,
        "primary": True,
        "scope": "Complete public Runway model inventory at the inventory date.",
    },
    "runway-changelog": {
        "title": "Runway Dev API changelog",
        "url": "https://docs.dev.runwayml.com/api-details/api_changelog/",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.96,
        "primary": True,
        "scope": "Version-specific limits for newly added Runway models.",
    },
    "google-image": {
        "title": "Google Gemini image generation documentation",
        "url": "https://ai.google.dev/gemini-api/docs/image-generation",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.99,
        "primary": True,
        "scope": "Gemini image IDs, reference/identity capacity, resolutions and aspect ratios.",
    },
    "google-deprecations": {
        "title": "Google Gemini model deprecations",
        "url": "https://ai.google.dev/gemini-api/docs/deprecations",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.99,
        "primary": True,
        "scope": "Stable and retired Gemini image aliases.",
    },
    "world-models": {
        "title": "World Labs API model inventory",
        "url": "https://docs.worldlabs.ai/api/models",
        "observed_at": OBSERVED_AT,
        "kind": "documented_api",
        "confidence": 0.99,
        "primary": True,
        "scope": "Complete public Marble model inventory at the inventory date.",
    },
    "owner-pending-defensive": {
        "title": "Defensive numeric policy awaiting owner confirmation",
        "url": None,
        "observed_at": OBSERVED_AT,
        "kind": "defensive",
        "confidence": 1.0,
        "primary": False,
        "scope": "Explicit conservative values; pending means they are not represented as owner-approved policy.",
    },
}


def ident(family: str, variant: str, version: str, modality: str) -> Identity:
    return Identity(family, variant, version, modality)


def fal_source(endpoint_id: str) -> str:
    source_id = "fal:" + endpoint_id
    if source_id not in SOURCES:
        SOURCES[source_id] = {
            "title": f"fal endpoint metadata: {endpoint_id}",
            "url": "https://api.fal.ai/v1/models?endpoint_id=" + quote(endpoint_id, safe=""),
            "observed_at": OBSERVED_AT,
            "kind": "provider_schema",
            "confidence": 0.92,
            "primary": True,
            "scope": "Free endpoint metadata lookup; no generation call.",
        }
    return source_id


INVENTORY: list[dict[str, Any]] = []


def offer(
    catalog_id: str,
    provider: str,
    provider_model_id: str,
    modality: str,
    *,
    identity: Identity | None,
    sources: list[str],
    origins: list[str],
    expected: str = "exact",
    availability: str = "active",
    notes: str | None = None,
    fixture: bool = False,
) -> None:
    item: dict[str, Any] = {
        "catalog_model_id": catalog_id,
        "provider": provider,
        "provider_model_id": provider_model_id,
        "provider_qualified_alias": f"{provider}::{provider_model_id}",
        "modality": modality,
        "origins": origins,
        "source_ids": sources,
        "expected_resolution": expected,
        "availability": availability,
        "fixture": fixture,
    }
    if identity is not None:
        item.update(identity.json())
    if notes:
        item["notes"] = notes
    INVENTORY.append(item)


def fal_offer(
    catalog_id: str,
    modality: str,
    identity: Identity | None,
    *,
    provider_model_id: str | None = None,
    origins: list[str] | None = None,
    availability: str = "active",
    notes: str | None = None,
) -> None:
    ref = provider_model_id or catalog_id
    offer(
        catalog_id,
        "fal",
        ref,
        modality,
        identity=identity,
        sources=[fal_source(ref)],
        origins=origins or ["offline_registry"],
        availability=availability,
        notes=notes,
        expected="exact" if identity else "defensive",
    )


# fal.ai offline registry and checked-in catalog.
fal_offer("fal-ai/flux/schnell", "image", ident("flux", "schnell", "1", "image"))
fal_offer("fal-ai/flux/dev", "image", ident("flux", "dev", "1", "image"))
fal_offer("fal-ai/flux-pro/v1.1", "image", ident("flux-pro", "standard", "1.1", "image"))
fal_offer("fal-ai/flux-pro/v1.1-ultra", "image", ident("flux-pro", "ultra", "1.1", "image"))
fal_offer("fal-ai/recraft/v3/text-to-image", "image", ident("recraft", "text-to-image", "3", "image"))
fal_offer("fal-ai/ideogram/v3", "image", ident("ideogram", "text-to-image", "3", "image"))
fal_offer(
    "fal-ai/imagen4",
    "image",
    ident("imagen", "text-to-image", "4", "image"),
    availability="stale",
    notes="Free model lookup returned HTTP 404 on the inventory date; retained because the offline registry still ships it.",
)
SOURCES[fal_source("fal-ai/imagen4")].update(
    title="fal endpoint lookup result: fal-ai/imagen4",
    confidence=0.99,
    scope="Free endpoint metadata lookup returned HTTP 404; no generation call.",
)
fal_offer(
    "fal-ai/qwen-image",
    "image",
    None,
    notes="The curated endpoint is unversioned; it remains defensive/research-needed rather than guessing a model version.",
)
fal_offer("fal-ai/stable-diffusion-v35-large", "image", ident("stable-diffusion", "large", "3.5", "image"))

gemini25 = ident("gemini-image", "unified", "2.5-flash", "image")
gemini31 = ident("gemini-image", "unified", "3.1-flash", "image")
gemini3pro = ident("gemini-image", "unified", "3-pro", "image")
gpt_image2 = ident("gpt-image", "unified", "2", "image")
fal_offer("fal-ai/nano-banana", "image", gemini25)
fal_offer("fal-ai/nano-banana-2", "image", gemini31)
fal_offer("fal-ai/nano-banana-pro", "image", gemini3pro)
fal_offer("fal-ai/gpt-image-2", "image", gpt_image2)
fal_offer("fal-ai/flux-pro/kontext", "image", ident("flux-kontext", "pro", "1", "image"))
fal_offer(
    "fal-ai/gemini-25-flash-image/edit",
    "image",
    gemini25,
    provider_model_id="fal-ai/nano-banana/edit",
)
fal_offer("fal-ai/nano-banana-2/edit", "image", gemini31)
fal_offer("fal-ai/nano-banana-pro/edit", "image", gemini3pro)
fal_offer("fal-ai/gpt-image-2/edit", "image", gpt_image2, provider_model_id="openai/gpt-image-2/edit")

kling25_text = ident("kling", "text-to-video", "2.5-turbo-pro", "video")
kling25_image = ident("kling", "image-to-video", "2.5-turbo-pro", "video")
seedance1_text = ident("seedance", "text-to-video", "1.0", "video")
seedance1_image = ident("seedance", "image-to-video", "1.0", "video")
seedance2_text = ident("seedance", "text-to-video", "2.0", "video")
seedance2_image = ident("seedance", "image-to-video", "2.0", "video")
seedance2_ref = ident("seedance", "reference-to-video", "2.0", "video")
seedance25_text = ident("seedance", "text-to-video", "2.5", "video")
seedance25_image = ident("seedance", "image-to-video", "2.5", "video")
seedance25_ref = ident("seedance", "reference-to-video", "2.5", "video")
fal_offer("fal-ai/kling-video/v2.5-turbo/pro/text-to-video", "video", kling25_text)
fal_offer("fal-ai/bytedance/seedance/v1/pro/text-to-video", "video", seedance1_text)
fal_offer("bytedance/seedance-2.0/text-to-video", "video", seedance2_text)
fal_offer("bytedance/seedance-2.0/reference-to-video", "video", seedance2_ref)
fal_offer("fal-ai/veo3", "video", ident("veo", "text-to-video", "3", "video"))
fal_offer("fal-ai/minimax/hailuo-02/standard/text-to-video", "video", ident("hailuo", "text-to-video-standard", "2.0", "video"))
fal_offer("fal-ai/kling-video/v2.5-turbo/pro/image-to-video", "video", kling25_image)
fal_offer("fal-ai/bytedance/seedance/v1/pro/image-to-video", "video", seedance1_image)
fal_offer("bytedance/seedance-2.0/image-to-video", "video", seedance2_image)
fal_offer(
    "bytedance/seedance-2.5/text-to-video",
    "video",
    seedance25_text,
    origins=["offline_registry", "catalog/models.json", "free_provider_schema"],
)
fal_offer(
    "bytedance/seedance-2.5/image-to-video",
    "video",
    seedance25_image,
    origins=["offline_registry", "catalog/models.json", "free_provider_schema"],
)
fal_offer(
    "bytedance/seedance-2.5/reference-to-video",
    "video",
    seedance25_ref,
    origins=["offline_registry", "catalog/models.json", "free_provider_schema"],
)

eleven_tts = ident("elevenlabs", "multilingual-tts", "2", "audio")
fal_offer("fal-ai/elevenlabs/tts/multilingual-v2", "audio", eleven_tts)
fal_offer(
    "fal-ai/elevenlabs/sound-effects",
    "audio",
    None,
    notes="The endpoint is curated but unversioned; exact version evidence is unresolved.",
)
fal_offer(
    "fal-ai/stable-audio",
    "music",
    None,
    notes="The endpoint is curated but unversioned; exact model version evidence is unresolved.",
)
fal_offer(
    "fal-ai/elevenlabs/music",
    "music",
    None,
    notes="The endpoint is curated but unversioned; exact model version evidence is unresolved.",
)
fal_offer(
    "fal-ai/clarity-upscaler",
    "image",
    None,
    notes="An unversioned image transformation endpoint; represented defensively until the capability schema has an upscale field.",
)
fal_offer(
    "fal-ai/topaz/upscale/video",
    "video",
    None,
    notes="An unversioned video transformation endpoint; represented defensively until the capability schema has an upscale field.",
)


# Runway offline registry plus its complete free public model inventory.
RUNWAY_SOURCE = ["runway-models"]


def runway_offer(
    catalog_id: str,
    api_model: str,
    modality: str,
    identity: Identity | None,
    *,
    offline: bool = False,
    notes: str | None = None,
) -> None:
    offer(
        catalog_id,
        "runway",
        api_model,
        modality,
        identity=identity,
        sources=RUNWAY_SOURCE,
        origins=["offline_registry", "free_provider_inventory"] if offline else ["free_provider_inventory"],
        expected="exact" if identity else "defensive",
        notes=notes,
    )


runway_gen45 = ident("runway-gen", "image-to-video", "4.5", "video")
runway_gen4_turbo = ident("runway-gen", "image-to-video-turbo", "4", "video")
runway_offer("runway/gen4.5", "gen4.5", "video", runway_gen45, offline=True)
runway_offer("runway/gen4_turbo", "gen4_turbo", "video", runway_gen4_turbo, offline=True)
runway_offer("runway/aleph2", "aleph2", "video", ident("runway-aleph", "video-edit", "2", "video"), offline=True)
runway_offer("runway/gen4_image_turbo", "gen4_image_turbo", "image", ident("runway-gen-image", "turbo", "4", "image"), offline=True)
runway_offer("runway/gen4_image", "gen4_image", "image", ident("runway-gen-image", "standard", "4", "image"), offline=True)
runway_offer("runway/gpt_image_2", "gpt_image_2", "image", gpt_image2, offline=True)
runway_offer("runway/gemini_image3_pro", "gemini_image3_pro", "image", gemini3pro, offline=True)
runway_offer("runway/gemini_image3.1_flash", "gemini_image3.1_flash", "image", gemini31, offline=True)
runway_offer("runway/seedream5_pro", "seedream5_pro", "image", ident("seedream", "pro", "5", "image"), offline=True)
runway_offer("runway/seedream5_lite", "seedream5_lite", "image", ident("seedream", "lite", "5", "image"), offline=True)
runway_offer("runway/grok_imagine_image_2", "grok_imagine_image_2", "image", ident("grok-imagine-image", "standard", "2", "image"), offline=True)
runway_offer("runway/gemini_2.5_flash", "gemini_2.5_flash", "image", gemini25, offline=True)

runway_public = [
    ("wan3", "video", ident("wan", "multimodal", "3", "video")),
    ("seedance2_5", "video", ident("seedance", "multimodal", "2.5", "video")),
    ("grok_imagine_1_5", "video", ident("grok-imagine-video", "standard", "1.5", "video")),
    ("seedance2", "video", ident("seedance", "multimodal", "2.0", "video")),
    ("seedance2_fast", "video", ident("seedance", "multimodal-fast", "2.0", "video")),
    ("seedance2_mini", "video", ident("seedance", "multimodal-mini", "2.0", "video")),
    ("hailuo3", "video", ident("minimax-h3", "ref2va", "3", "video")),
    ("act_two", "video", ident("runway-act", "performance-capture", "2", "video")),
    ("veo3.1", "video", ident("veo", "multimodal", "3.1", "video")),
    ("veo3.1_fast", "video", ident("veo", "multimodal-fast", "3.1", "video")),
    ("happyhorse_1_0", "video", ident("happyhorse", "multimodal", "1.0", "video")),
    ("gemini_omni_flash", "video", ident("gemini-omni", "flash", "1", "video")),
    ("gwm1_avatars", "video", ident("runway-gwm", "avatars", "1", "video")),
    ("muse_image", "image", ident("muse-image", "standard", "1", "image")),
    ("seed_audio", "audio", ident("seed-audio", "multimodal", "1.0", "audio")),
    ("eleven_v3", "audio", ident("elevenlabs", "tts", "3", "audio")),
    ("eleven_multilingual_v2", "audio", eleven_tts),
    ("eleven_text_to_sound_v2", "audio", ident("elevenlabs", "text-to-sound", "2", "audio")),
    ("eleven_voice_isolation", "audio", None),
    ("eleven_voice_dubbing", "audio", None),
    ("eleven_multilingual_sts_v2", "audio", ident("elevenlabs", "speech-to-speech", "2", "audio")),
    ("magnific_precision_upscaler_v2", "image", ident("magnific", "image-upscale", "2", "image")),
    ("magnific_video_upscaler_creative", "video", None),
    ("ruby", "video", None),
]
for api_model, modality, identity in runway_public:
    runway_offer(
        f"runway/{api_model}",
        api_model,
        modality,
        identity,
        notes=None if identity else "The public provider code is unversioned or is a transformation outside the current capability field set.",
    )


# Google direct image inventory, including retired candidates still named by the offline registry.
def google_offer(
    catalog_id: str,
    api_model: str,
    identity: Identity,
    *,
    offline: bool = False,
    availability: str = "active",
) -> None:
    offer(
        catalog_id,
        "google",
        api_model,
        "image",
        identity=identity,
        sources=["google-image", "google-deprecations"],
        origins=["offline_registry", "free_provider_inventory"] if offline else ["free_provider_inventory"],
        availability=availability,
    )


google_offer("fal-ai/gemini-25-flash-image/edit", "gemini-2.5-flash-image", gemini25, offline=True)
google_offer("google/gemini-3-pro-image", "gemini-3-pro-image", gemini3pro, offline=True)
google_offer("google/gemini-3.1-flash-image", "gemini-3.1-flash-image", gemini31, offline=True)
google_offer("google/gemini-3.1-flash-lite-image", "gemini-3.1-flash-lite-image", ident("gemini-image", "unified", "3.1-flash-lite", "image"))
google_offer("google/gemini-3-pro-image", "gemini-3-pro-image-preview", gemini3pro, offline=True, availability="stale")
google_offer("google/gemini-3.1-flash-image", "gemini-3.1-flash-image-preview", gemini31, offline=True, availability="stale")


# World Labs public inventory.
for version, label in [
    ("1.1-plus", "plus"),
    ("1.1", "standard"),
    ("1.0", "standard"),
    ("1.0-draft", "draft"),
]:
    catalog_id = "marble/marble-1.1" if version == "1.1" else f"marble/marble-{version}"
    offer(
        catalog_id,
        "marble",
        f"marble-{version}",
        "image",
        identity=ident("marble", label, version.split("-")[0], "image"),
        sources=["world-models"],
        origins=["offline_registry", "free_provider_inventory"] if version == "1.1" else ["free_provider_inventory"],
    )


# Mandatory top-tier MiniMax H3 free live schema inventory.
h3_fl2va = ident("minimax-h3", "fl2va", "3", "video")
h3_ref2va = ident("minimax-h3", "ref2va", "3", "video")
for endpoint_id, identity in [
    ("minimax/h3/text-to-video", h3_fl2va),
    ("minimax/h3/image-to-video", h3_fl2va),
    ("minimax/h3/reference-to-video", h3_ref2va),
]:
    offer(
        endpoint_id,
        "fal",
        endpoint_id,
        "video",
        identity=identity,
        sources=["minimax-h3", "fal-minimax-h3"],
        origins=["free_provider_schema", "required_top_tier"],
    )


# Explicit resolver fixtures required by the issue.
offer(
    "fixture/seedance-3.0/reference-to-video",
    "fixture",
    "seedance-3.0-reference",
    "video",
    identity=ident("seedance", "reference-to-video", "3.0", "video"),
    sources=["fal-seedance-2.5"],
    origins=["synthetic_fixture"],
    expected="inherited",
    availability="research-needed",
    fixture=True,
)
offer(
    "fixture/hupfntrupfn",
    "fixture",
    "hupfntrupfn",
    "video",
    identity=None,
    sources=["owner-pending-defensive"],
    origins=["synthetic_fixture"],
    expected="defensive",
    availability="research-needed",
    fixture=True,
)


PROFILES: dict[Identity, ProfileSpec] = {}


def ensure_profile(identity: Identity, source_ids: list[str]) -> ProfileSpec:
    spec = PROFILES.setdefault(identity, ProfileSpec(identity))
    spec.source_ids.update(source_ids)
    return spec


def put(
    identity: Identity,
    field_id: str,
    value: Any,
    semantics: str,
    source_ids: list[str],
    *,
    conflict: str | None = None,
) -> None:
    spec = ensure_profile(identity, source_ids)
    spec.gaps.pop(field_id, None)
    spec.fields[field_id] = {
        "value": value,
        "semantics": semantics,
        "source_ids": source_ids,
        **({"conflict": conflict} if conflict else {}),
    }


def gap(identity: Identity, field_id: str, note: str) -> None:
    PROFILES[identity].gaps[field_id] = note


# Every exact inventory identity receives a primary-sourced exact profile. Sparse profiles keep
# unknown capability fields unknown; defensive values fill resolution while the report names gaps.
for item in INVENTORY:
    if item["expected_resolution"] != "exact" or "family_id" not in item:
        continue
    identity = Identity(
        item["family_id"], item["variant_id"], item["version_id"], item["modality"]
    )
    spec = ensure_profile(identity, item["source_ids"])
    put(identity, "common.output_kinds", [item["modality"]], "supported_set", item["source_ids"])
    for field_id in sorted(REQUIRED_BY_MODALITY[item["modality"]] - set(spec.fields)):
        spec.gaps.setdefault(field_id, "No field-specific primary-source value was captured at this inventory date.")


def set_inputs(identity: Identity, values: list[str], sources: list[str]) -> None:
    put(identity, "common.input_kinds", values, "supported_set", sources)


def set_outputs(identity: Identity, values: list[str], sources: list[str]) -> None:
    put(identity, "common.output_kinds", values, "supported_set", sources)


# Explicit lineage is never inferred lexically.
for current, predecessor in [
    (seedance2_text, "1.0"),
    (seedance25_text, "2.0"),
    (seedance2_image, "1.0"),
    (seedance25_image, "2.0"),
    (seedance25_ref, "2.0"),
]:
    PROFILES[current].predecessor = predecessor


FAL_SCHEMA = ["fal-model-api"]
SEEDANCE25 = ["fal-seedance-2.5"]
SEEDANCE25_RELIABLE = ["fal-seedance-2.5-guide"]
H3_SOURCES = ["minimax-h3", "fal-minimax-h3"]
RUNWAY = ["runway-models", "runway-changelog"]
GOOGLE = ["google-image"]


for identity in [seedance25_text, seedance25_image, seedance25_ref]:
    put(identity, "video.duration_minimum_seconds", 4.0, "hard_api_limit", SEEDANCE25)
    put(identity, "video.duration_maximum_seconds", 30.0, "hard_api_limit", SEEDANCE25)
    put(identity, "video.duration_automatic", True, "supported_value", SEEDANCE25)
    put(identity, "video.fps_values", [24], "supported_set", SEEDANCE25)
    put(identity, "video.native_audio", True, "supported_value", SEEDANCE25)
    put(identity, "video.lip_sync", True, "supported_value", SEEDANCE25)
    put(
        identity,
        "common.resolutions",
        ["480p", "720p", "1080p"],
        "supported_set",
        SEEDANCE25,
        conflict="The checked-in catalog listed 480p/720p; current text/image API docs also list 1080p.",
    )
    put(identity, "common.aspect_ratios", ["auto", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"], "supported_set", SEEDANCE25)

set_inputs(seedance25_text, ["text"], SEEDANCE25)
put(seedance25_text, "video.reference_images", 0, "hard_api_limit", SEEDANCE25)
put(seedance25_text, "video.reference_videos", 0, "hard_api_limit", SEEDANCE25)
put(seedance25_text, "video.reference_audios", 0, "hard_api_limit", SEEDANCE25)
put(seedance25_text, "video.total_references", 0, "hard_api_limit", SEEDANCE25)
put(seedance25_text, "video.first_frame", False, "supported_value", SEEDANCE25)
put(seedance25_text, "video.last_frame", False, "supported_value", SEEDANCE25)
put(seedance25_text, "video.source_video", False, "supported_value", SEEDANCE25)
put(seedance25_text, "video.edit", False, "supported_value", SEEDANCE25)
put(seedance25_text, "video.extend", False, "supported_value", SEEDANCE25)

set_inputs(seedance25_image, ["text", "image"], SEEDANCE25)
put(seedance25_image, "video.reference_images", 2, "hard_api_limit", SEEDANCE25)
put(seedance25_image, "video.reference_videos", 0, "hard_api_limit", SEEDANCE25)
put(seedance25_image, "video.reference_audios", 0, "hard_api_limit", SEEDANCE25)
put(seedance25_image, "video.total_references", 2, "hard_api_limit", SEEDANCE25)
put(seedance25_image, "video.first_frame", True, "supported_value", SEEDANCE25)
put(seedance25_image, "video.last_frame", True, "supported_value", SEEDANCE25)
put(seedance25_image, "video.source_video", False, "supported_value", SEEDANCE25)
put(seedance25_image, "video.edit", False, "supported_value", SEEDANCE25)
put(seedance25_image, "video.extend", False, "supported_value", SEEDANCE25)

set_inputs(seedance25_ref, ["text", "image", "video", "audio"], SEEDANCE25)
put(seedance25_ref, "video.visible_characters", 5, "reliable_capacity", SEEDANCE25_RELIABLE)
put(seedance25_ref, "video.reference_images", 30, "hard_api_limit", SEEDANCE25)
put(seedance25_ref, "video.reference_videos", 10, "hard_api_limit", SEEDANCE25)
put(seedance25_ref, "video.reference_audios", 10, "hard_api_limit", SEEDANCE25)
put(seedance25_ref, "video.total_references", 50, "hard_api_limit", SEEDANCE25)
put(seedance25_ref, "video.combined_video_reference_seconds", 30.0, "hard_api_limit", SEEDANCE25_RELIABLE)
put(seedance25_ref, "video.source_video", True, "supported_value", SEEDANCE25)
put(seedance25_ref, "video.edit", True, "supported_value", SEEDANCE25)
put(seedance25_ref, "video.extend", True, "supported_value", SEEDANCE25)

# Seedance 2.0 exact high-reference predecessor.
for identity in [seedance2_text, seedance2_image, seedance2_ref]:
    put(identity, "video.duration_minimum_seconds", 4.0, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(identity, "video.duration_maximum_seconds", 15.0, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(identity, "video.duration_automatic", True, "supported_value", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(identity, "video.native_audio", True, "supported_value", [fal_source("bytedance/seedance-2.0/reference-to-video")])
if seedance2_ref in PROFILES:
    put(seedance2_ref, "video.reference_images", 9, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(seedance2_ref, "video.reference_videos", 3, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(seedance2_ref, "video.reference_audios", 3, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(seedance2_ref, "video.total_references", 12, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(seedance2_ref, "video.combined_video_reference_seconds", 15.0, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])
    put(seedance2_ref, "video.combined_audio_reference_seconds", 15.0, "hard_api_limit", [fal_source("bytedance/seedance-2.0/reference-to-video")])


# MiniMax H3 creator truth, with provider differences recorded rather than collapsed.
for identity in [h3_fl2va, h3_ref2va]:
    set_outputs(identity, ["video", "audio"], H3_SOURCES)
    put(
        identity,
        "video.duration_minimum_seconds",
        4.0,
        "hard_api_limit",
        H3_SOURCES,
        conflict="MiniMax documents 4–15 seconds; the live fal reference endpoint schema currently enforces 5–15 seconds.",
    )
    put(identity, "video.duration_maximum_seconds", 15.0, "hard_api_limit", H3_SOURCES)
    put(identity, "video.fps_values", [24], "supported_set", ["minimax-h3"])
    put(identity, "video.native_audio", True, "supported_value", ["minimax-h3"])
    put(identity, "video.lip_sync", True, "supported_value", ["minimax-h3", "fal-minimax-h3"])
    put(
        identity,
        "common.resolutions",
        ["768p", "2K"],
        "supported_set",
        H3_SOURCES,
        conflict="MiniMax specifies native 768p and API 2K; fal also exposes provider-side 480P and 4K choices.",
    )
    put(identity, "common.aspect_ratios", ["adaptive", "21:9", "16:9", "4:3", "1:1", "3:4", "9:16"], "supported_set", H3_SOURCES)
    put(
        identity,
        "common.prompt_characters",
        7000,
        "reliable_capacity",
        ["fal-minimax-h3-product", "fal-minimax-h3"],
        conflict="fal's product documentation recommends 7,000 characters while the live OpenAPI maxLength is 50,000.",
    )
    gap(identity, "video.visible_characters", "No primary source states a numeric reliable on-screen figure capacity; it remains unknown instead of being inferred from reference-file count.")

set_inputs(h3_fl2va, ["text", "image"], H3_SOURCES)
put(h3_fl2va, "video.reference_images", 2, "hard_api_limit", ["minimax-h3"])
put(h3_fl2va, "video.reference_videos", 0, "hard_api_limit", ["minimax-h3"])
put(h3_fl2va, "video.reference_audios", 0, "hard_api_limit", ["minimax-h3"])
put(h3_fl2va, "video.total_references", 2, "hard_api_limit", ["minimax-h3"])
put(h3_fl2va, "video.first_frame", True, "supported_value", ["minimax-h3"])
put(h3_fl2va, "video.last_frame", True, "supported_value", ["minimax-h3"])

set_inputs(h3_ref2va, ["text", "image", "video", "audio"], H3_SOURCES)
put(h3_ref2va, "video.reference_images", 9, "hard_api_limit", H3_SOURCES)
put(h3_ref2va, "video.reference_videos", 3, "hard_api_limit", H3_SOURCES)
put(h3_ref2va, "video.reference_audios", 3, "hard_api_limit", H3_SOURCES)
put(h3_ref2va, "video.total_references", 12, "hard_api_limit", H3_SOURCES)
put(h3_ref2va, "video.combined_video_reference_seconds", 15.0, "hard_api_limit", H3_SOURCES)
put(h3_ref2va, "video.combined_audio_reference_seconds", 15.0, "hard_api_limit", H3_SOURCES)
put(h3_ref2va, "video.source_video", True, "supported_value", H3_SOURCES)
put(h3_ref2va, "video.edit", True, "supported_value", H3_SOURCES)
put(h3_ref2va, "video.extend", True, "supported_value", H3_SOURCES)


# Shared intrinsic image truth across providers.
for identity, refs, figures, resolutions in [
    (gemini25, 3, None, ["1K"]),
    (gemini3pro, 14, 5, ["1K", "2K", "4K"]),
    (gemini31, 14, 4, ["0.5K", "1K", "2K", "4K"]),
]:
    set_inputs(identity, ["text", "image"], GOOGLE)
    put(identity, "image.references", refs, "hard_api_limit", GOOGLE)
    put(identity, "image.identity", True, "supported_value", GOOGLE)
    put(identity, "image.edit", True, "supported_value", GOOGLE)
    put(identity, "image.outputs_per_request", 1, "reliable_capacity", GOOGLE)
    put(identity, "common.resolutions", resolutions, "supported_set", GOOGLE)
    if figures is not None:
        put(identity, "image.visible_characters", figures, "reliable_capacity", GOOGLE)

if gpt_image2 in PROFILES:
    set_inputs(gpt_image2, ["text", "image"], RUNWAY)
    put(gpt_image2, "image.references", 16, "hard_api_limit", RUNWAY)
    put(gpt_image2, "image.edit", True, "supported_value", RUNWAY)
    put(gpt_image2, "image.identity", True, "supported_value", RUNWAY)
    put(gpt_image2, "image.outputs_per_request", 4, "hard_api_limit", RUNWAY)

for identity, refs, outputs in [
    (ident("seedream", "pro", "5", "image"), 10, 4),
    (ident("seedream", "lite", "5", "image"), 14, 4),
    (ident("grok-imagine-image", "standard", "2", "image"), 3, 4),
]:
    if identity in PROFILES:
        set_inputs(identity, ["text", "image"], RUNWAY)
        put(identity, "image.references", refs, "hard_api_limit", RUNWAY)
        put(identity, "image.edit", True, "supported_value", RUNWAY)
        put(identity, "image.outputs_per_request", outputs, "hard_api_limit", RUNWAY)

for identity in [runway_gen45, runway_gen4_turbo]:
    set_inputs(identity, ["text", "image"], RUNWAY)
    put(identity, "video.reference_images", 1, "hard_api_limit", RUNWAY)
    put(identity, "video.first_frame", True, "supported_value", RUNWAY)
for identity, values in [(runway_gen45, [4, 6, 8, 10]), (runway_gen4_turbo, [5, 10])]:
    put(identity, "video.duration_values_seconds", values, "supported_set", RUNWAY)

aleph2 = ident("runway-aleph", "video-edit", "2", "video")
if aleph2 in PROFILES:
    set_inputs(aleph2, ["text", "video", "image"], RUNWAY)
    put(aleph2, "video.source_video", True, "supported_value", RUNWAY)
    put(aleph2, "video.edit", True, "supported_value", RUNWAY)
    put(aleph2, "video.reference_images", 5, "hard_api_limit", RUNWAY)
    put(aleph2, "video.duration_minimum_seconds", 2.0, "hard_api_limit", RUNWAY)
    put(aleph2, "video.duration_maximum_seconds", 30.0, "hard_api_limit", RUNWAY)


def evidence(source_id: str, conflict: str | None = None) -> dict[str, Any]:
    source = SOURCES[source_id]
    result = {
        "source_url": source["url"],
        "source_title": source["title"],
        "observed_at": source["observed_at"],
        "kind": source["kind"],
        "confidence": source["confidence"],
    }
    if conflict:
        result["conflict"] = conflict
    return result


def materialize_field(spec: dict[str, Any]) -> dict[str, Any]:
    return {
        "value": spec["value"],
        "semantics": spec["semantics"],
        "evidence": [evidence(source_id, spec.get("conflict")) for source_id in spec["source_ids"]],
    }


def defensive_value(field_id: str) -> Any:
    field_type = FIELD_TYPES[field_id]
    if field_type == "integers":
        if field_id in {
            "video.visible_characters",
            "video.reference_images",
            "image.visible_characters",
            "image.references",
            "image.outputs_per_request",
        }:
            return 1
        return 0
    if field_type == "decimals":
        return 30.0 if field_id.endswith("maximum_seconds") else 0.0
    if field_type == "booleans":
        return False
    return []


def build_knowledge_base() -> dict[str, Any]:
    profiles: list[dict[str, Any]] = []
    aliases: dict[tuple[str, Identity], None] = {}
    for identity, spec in sorted(PROFILES.items()):
        typed = {
            "integers": {},
            "decimals": {},
            "booleans": {},
            "strings": {},
            "integer_lists": {},
        }
        for field_id, value in sorted(spec.fields.items()):
            typed[FIELD_TYPES[field_id]][field_id] = materialize_field(value)
        profile = {"identity": identity.json(), "fields": typed}
        if spec.predecessor:
            profile["predecessor_version_id"] = spec.predecessor
        profiles.append(profile)

    for item in INVENTORY:
        if item["expected_resolution"] != "exact" or "family_id" not in item:
            continue
        identity = Identity(item["family_id"], item["variant_id"], item["version_id"], item["modality"])
        for alias in {
            item["catalog_model_id"],
            item["provider_model_id"],
            item["provider_qualified_alias"],
        }:
            aliases[(alias, identity)] = None

    defensive_profiles = []
    for modality in ["video", "image", "audio", "music"]:
        typed = {
            "integers": {},
            "decimals": {},
            "booleans": {},
            "strings": {},
            "integer_lists": {},
        }
        for field_id in sorted(REQUIRED_BY_MODALITY[modality]):
            typed[FIELD_TYPES[field_id]][field_id] = {
                "value": defensive_value(field_id),
                "semantics": "defensive_default",
                "evidence": [evidence("owner-pending-defensive")],
            }
        defensive_profiles.append(
            {
                "id": f"defensive.{modality}.owner-pending-v1",
                "modality": modality,
                "fields": typed,
            }
        )

    return {
        "schema": KB_SCHEMA,
        "profiles": profiles,
        "aliases": [
            {"catalog_model_id": alias, "identity": identity.json()}
            for alias, identity in sorted(aliases)
        ],
        "defensive_profiles": defensive_profiles,
    }


def source_list() -> list[dict[str, Any]]:
    return [{"id": source_id, **source} for source_id, source in sorted(SOURCES.items())]


def profile_gaps() -> list[dict[str, Any]]:
    return [
        {"identity": identity.json(), "fields": dict(sorted(spec.gaps.items()))}
        for identity, spec in sorted(PROFILES.items())
        if spec.gaps
    ]


def build_corpus() -> dict[str, Any]:
    return {
        "schema": CORPUS_SCHEMA,
        "observed_at": OBSERVED_AT,
        "stale_after_days": STALE_AFTER_DAYS,
        "defensive_defaults": {
            "owner_confirmation": "pending",
            "table": {
                "character_and_primary_reference_counts": 1,
                "image_outputs_per_request": 1,
                "other_integer_counts": 0,
                "duration_minimum_seconds": 0,
                "duration_maximum_seconds": 30,
                "booleans": False,
                "sets": [],
            },
        },
        "sources": source_list(),
        "inventory": sorted(
            INVENTORY,
            key=lambda item: (
                item["fixture"],
                item["modality"],
                item["catalog_model_id"],
                item["provider"],
                item["provider_model_id"],
            ),
        ),
        "profile_gaps": profile_gaps(),
        "knowledge_base": build_knowledge_base(),
        "unavailable_inventories": [
            {
                "provider": "higgsfield",
                "reason": "The effective catalog is available only through the user's authenticated MCP session; no unauthenticated list endpoint was found.",
            },
            {
                "provider": "openart",
                "reason": "The effective catalog is available only through the user's authenticated MCP session; no unauthenticated list endpoint was found.",
            },
        ],
    }


def parse_date(value: str) -> dt.date:
    return dt.date.fromisoformat(value)


def inventory_resolution(item: dict[str, Any], kb: dict[str, Any]) -> str:
    aliases = {
        alias["catalog_model_id"]: Identity(
            alias["identity"]["family_id"],
            alias["identity"]["variant_id"],
            alias["identity"]["version_id"],
            alias["identity"]["modality"],
        )
        for alias in kb["aliases"]
    }
    profiles = {
        Identity(
            profile["identity"]["family_id"],
            profile["identity"]["variant_id"],
            profile["identity"]["version_id"],
            profile["identity"]["modality"],
        )
        for profile in kb["profiles"]
    }
    if item["catalog_model_id"] in aliases:
        return "exact"
    if "family_id" not in item:
        return "defensive"
    requested = Identity(item["family_id"], item["variant_id"], item["version_id"], item["modality"])
    if requested in profiles:
        return "exact"
    family_profiles = {
        profile
        for profile in profiles
        if profile.family == requested.family
        and profile.variant == requested.variant
        and profile.modality == requested.modality
    }
    return "inherited" if family_profiles else "defensive"


def profile_has_conflict(identity: Identity) -> bool:
    spec = PROFILES.get(identity)
    return bool(spec and any("conflict" in value for value in spec.fields.values()))


def coverage_rows(corpus: dict[str, Any]) -> list[dict[str, Any]]:
    kb = corpus["knowledge_base"]
    rows = []
    for item in corpus["inventory"]:
        actual = inventory_resolution(item, kb)
        identity = None
        if "family_id" in item:
            identity = Identity(item["family_id"], item["variant_id"], item["version_id"], item["modality"])
        conflicts = bool(identity and profile_has_conflict(identity))
        stale = item["availability"] == "stale"
        gaps = bool(identity and PROFILES.get(identity) and PROFILES[identity].gaps)
        rows.append(
            {
                **item,
                "actual_resolution": actual,
                "stale": stale,
                "conflicting": conflicts,
                "research_needed": actual != "exact" or stale or conflicts or gaps,
            }
        )
    return rows


def validate(corpus: dict[str, Any]) -> None:
    if corpus["schema"] != CORPUS_SCHEMA:
        raise ValueError("unsupported corpus schema")
    if corpus["knowledge_base"]["schema"] != KB_SCHEMA:
        raise ValueError("unsupported knowledge-base schema")
    source_ids = {source["id"] for source in corpus["sources"]}
    if len(source_ids) != len(corpus["sources"]):
        raise ValueError("duplicate source id")
    source_titles = {source["title"] for source in corpus["sources"]}
    if len(source_titles) != len(corpus["sources"]):
        raise ValueError("duplicate source title")
    inventory_date = parse_date(corpus["observed_at"])
    if corpus["stale_after_days"] <= 0:
        raise ValueError("stale threshold must be positive")
    for source in corpus["sources"]:
        observed_at = parse_date(source["observed_at"])
        if observed_at > inventory_date:
            raise ValueError(f"source observed after inventory: {source['id']}")
        if not 0 <= source["confidence"] <= 1:
            raise ValueError(f"invalid source confidence: {source['id']}")
        if source["url"] and not source["url"].startswith("https://"):
            raise ValueError(f"non-HTTPS source: {source['id']}")
        if "api.fal.ai" in (source["url"] or "") and "/v1/models?" not in source["url"]:
            raise ValueError(f"generation probe URL is forbidden: {source['id']}")
    inventory_keys = set()
    provider_aliases = set()
    for item in corpus["inventory"]:
        key = (item["provider"], item["provider_model_id"], item["modality"])
        if key in inventory_keys:
            raise ValueError(f"duplicate inventory offer: {key}")
        inventory_keys.add(key)
        expected_alias = f"{item['provider']}::{item['provider_model_id']}"
        if item["provider_qualified_alias"] != expected_alias:
            raise ValueError(f"non-canonical provider alias: {expected_alias}")
        if expected_alias in provider_aliases:
            raise ValueError(f"duplicate provider alias: {expected_alias}")
        provider_aliases.add(expected_alias)
        unknown_sources = set(item["source_ids"]) - source_ids
        if unknown_sources:
            raise ValueError(f"unknown inventory sources: {sorted(unknown_sources)}")
    aliases = {}
    for alias in corpus["knowledge_base"]["aliases"]:
        catalog_model_id = alias["catalog_model_id"]
        identity = alias["identity"]
        if catalog_model_id in aliases:
            raise ValueError(f"duplicate capability alias: {catalog_model_id}")
        aliases[catalog_model_id] = identity
    for item in corpus["inventory"]:
        if item["expected_resolution"] != "exact":
            continue
        expected_identity = {
            key: item[key]
            for key in ("family_id", "variant_id", "version_id", "modality")
        }
        for alias in (
            item["catalog_model_id"],
            item["provider_model_id"],
            item["provider_qualified_alias"],
        ):
            if aliases.get(alias) != expected_identity:
                raise ValueError(f"missing canonical capability alias: {alias}")
    for row in coverage_rows(corpus):
        if row["actual_resolution"] != row["expected_resolution"]:
            raise ValueError(
                f"coverage mismatch for {row['provider_qualified_alias']}: "
                f"expected {row['expected_resolution']}, got {row['actual_resolution']}"
            )
    for identity, spec in PROFILES.items():
        primary_sources = [SOURCES[source_id] for source_id in spec.source_ids if SOURCES[source_id]["primary"]]
        if not primary_sources:
            raise ValueError(f"exact profile has no primary source: {identity.key}")
        for field_id, field_spec in spec.fields.items():
            if not field_spec["source_ids"]:
                raise ValueError(f"field has no source: {identity.key} {field_id}")
            if not any(SOURCES[source_id]["primary"] for source_id in field_spec["source_ids"]):
                raise ValueError(f"field has no primary source: {identity.key} {field_id}")
        required = REQUIRED_BY_MODALITY[identity.modality]
        fields = set(spec.fields)
        gaps = set(spec.gaps)
        if fields & gaps or fields | gaps != required:
            raise ValueError(f"incomplete field classification: {identity.key}")
    defensive = corpus["knowledge_base"]["defensive_profiles"]
    for profile in defensive:
        present = set()
        for bucket in profile["fields"].values():
            present.update(bucket)
        expected = REQUIRED_BY_MODALITY[profile["modality"]]
        if present != expected:
            raise ValueError(f"incomplete defensive profile: {profile['modality']}")


def report(corpus: dict[str, Any]) -> str:
    rows = coverage_rows(corpus)
    counts = {kind: sum(row["actual_resolution"] == kind for row in rows) for kind in ["exact", "inherited", "defensive"]}
    stale = sum(row["stale"] for row in rows)
    conflicting = sum(row["conflicting"] for row in rows)
    research = sum(row["research_needed"] for row in rows)
    non_fixture = [row for row in rows if not row["fixture"]]
    lines = [
        "# Model capability coverage",
        "",
        f"Inventory date: `{corpus['observed_at']}`. Stale threshold: `{corpus['stale_after_days']} days`.",
        "The report is generated offline from the checked-in corpus; web access is not part of CI.",
        "",
        "## Summary",
        "",
        "| Offers | Non-fixture | Exact | Inherited | Defensive | Stale | Conflicting | Research-needed | Unclassified |",
        "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        f"| {len(rows)} | {len(non_fixture)} | {counts['exact']} | {counts['inherited']} | {counts['defensive']} | {stale} | {conflicting} | {research} | 0 |",
        "",
        "`exact` identifies a concrete intrinsic profile. `inherited` is an explicit family/variant lineage miss. `defensive` is used for unknown or deliberately unversioned IDs. Stale and conflicting evidence stays visible and forces research-needed.",
        "",
        "## Defensive numeric defaults — owner confirmation pending",
        "",
        "These values are explicit data, not inferred approval. Production activation remains blocked until the owner confirms or changes them.",
        "",
        "| Field group | Pending value |",
        "| --- | ---: |",
        "| Reliable visible-character / primary reference count | 1 |",
        "| Image outputs per request | 1 |",
        "| Other integer counts | 0 |",
        "| Minimum duration | 0 s |",
        "| Maximum duration | 30 s |",
        "| Boolean capabilities | false |",
        "| Supported sets | empty |",
        "",
        "## Coverage",
        "",
        "| Modality | Provider | Provider model | Catalog model | Profile | Resolution | Evidence |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        if "family_id" in row:
            profile = f"{row['family_id']}/{row['variant_id']}/{row['version_id']}"
        else:
            profile = "—"
        flags = []
        if row["stale"]:
            flags.append("stale")
        if row["conflicting"]:
            flags.append("conflict")
        if row["research_needed"]:
            flags.append("research-needed")
        evidence = ", ".join(flags) if flags else "current"
        lines.append(
            f"| {row['modality']} | {row['provider']} | `{row['provider_model_id']}` | "
            f"`{row['catalog_model_id']}` | `{profile}` | {row['actual_resolution']} | {evidence} |"
        )
    lines += [
        "",
        "## Primary sources",
        "",
    ]
    for source in corpus["sources"]:
        if not source["primary"]:
            continue
        lines.append(f"- [{source['title']}]({source['url']}) — {source['scope']}")
    lines += [
        "",
        "## Unresolved inventory access",
        "",
    ]
    for entry in corpus["unavailable_inventories"]:
        lines.append(f"- **{entry['provider']}** — {entry['reason']}")
    lines += [
        "",
        "## Evidence gaps",
        "",
        "Unknown numeric values remain null and resolve defensively; they are not estimated. The machine-readable `profile_gaps` map in the corpus lists every field-level gap. Notably, MiniMax H3 publishes high multimodal reference capacity but no numeric reliable on-screen figure capacity.",
        "",
    ]
    return "\n".join(lines)


def rendered() -> dict[Path, str]:
    corpus = build_corpus()
    validate(corpus)
    return {
        CORPUS_PATH: json.dumps(corpus, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        REPORT_PATH: report(corpus),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    failures = []
    for path, content in rendered().items():
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != content:
                failures.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    if failures:
        print("stale generated capability artifacts: " + ", ".join(failures))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
