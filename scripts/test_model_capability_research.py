#!/usr/bin/env python3
"""Static, offline contract checks for the model-capability research subsystem."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/NexGenVideoTests/Fixtures/ModelCapabilityResearch"
SCHEMA_SWIFT = ROOT / "Engine/Sources/NexGenEngine/Capabilities/ModelCapabilitySchemaV1.swift"
RESEARCH_SCHEMA_SWIFT = (
    ROOT / "Sources/NexGenVideo/Generation/Capabilities/ModelCapabilityResearchSchema.swift"
)
CORPUS_JSON = (
    ROOT
    / "Sources/NexGenVideo/Resources/ModelCapabilities/model-capability-corpus-v1.json"
)
TRANSPORT_SWIFT = (
    ROOT
    / "Sources/NexGenVideo/Generation/Capabilities/ClaudeModelCapabilityResearchTransport.swift"
)
HTML_SPEC = ROOT / "docs/ui/model-capability-research.html"

TOP_KEYS = {"schema", "binding", "scope", "fields"}
BINDING_KEYS = {
    "identity",
    "provider_id",
    "offering_id",
    "endpoint_id",
    "catalog_model_id",
    "mode",
}
IDENTITY_KEYS = {"family_id", "variant_id", "version_id", "modality"}
BUCKETS = {"integers", "decimals", "booleans", "strings", "integer_lists"}
FIELD_KEYS = {"value", "semantics", "evidence"}
EVIDENCE_KEYS = {
    "source_url",
    "source_title",
    "observed_at",
    "kind",
    "confidence",
    "conflict",
}
PRIMARY_HOSTS = {
    "google": {"ai.google.dev"},
    "runway": {"docs.dev.runwayml.com"},
    "elevenlabs": {"elevenlabs.io"},
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def registered_field_ids() -> set[str]:
    text = SCHEMA_SWIFT.read_text()
    return set(re.findall(r'public static let \w+ = "([^"]+)"', text))


def validate_fixture(path: Path, field_ids: set[str]) -> None:
    candidate = json.loads(path.read_text())
    require(set(candidate) == TOP_KEYS, f"{path.name}: top-level schema is not closed")
    require(candidate["schema"] == "model-capability-research-candidate/v1", path.name)
    binding = candidate["binding"]
    require(set(binding).issubset(BINDING_KEYS), f"{path.name}: unknown binding key")
    require(BINDING_KEYS - {"mode"} <= set(binding), f"{path.name}: incomplete binding")
    require(set(binding["identity"]) == IDENTITY_KEYS, f"{path.name}: identity is not closed")
    fields = candidate["fields"]
    require(set(fields) == BUCKETS, f"{path.name}: field buckets are not closed")
    populated = 0
    allowed_hosts = PRIMARY_HOSTS[binding["provider_id"]]
    for bucket in BUCKETS:
        for field_id, field in fields[bucket].items():
            populated += 1
            require(field_id in field_ids, f"{path.name}: unregistered field {field_id}")
            require(set(field) == FIELD_KEYS, f"{path.name}: {field_id} is not closed")
            require(field["evidence"], f"{path.name}: {field_id} has no evidence")
            for evidence in field["evidence"]:
                require(
                    set(evidence).issubset(EVIDENCE_KEYS),
                    f"{path.name}: unknown evidence key",
                )
                require(
                    EVIDENCE_KEYS - {"conflict"} <= set(evidence),
                    f"{path.name}: incomplete evidence",
                )
                parsed = urlparse(evidence["source_url"])
                require(parsed.scheme == "https", f"{path.name}: source must use HTTPS")
                require(parsed.hostname in allowed_hosts, f"{path.name}: non-primary source host")
                require(not parsed.username and not parsed.password, f"{path.name}: URL credentials")
                require(
                    evidence["kind"] in {"documented_api", "provider_schema", "inferred"},
                    f"{path.name}: invalid automated evidence kind",
                )
                require(0 <= evidence["confidence"] <= 1, f"{path.name}: confidence")
    require(populated > 0, f"{path.name}: empty candidate")


def validate_transport() -> None:
    text = TRANSPORT_SWIFT.read_text()
    for token in (
        '"--restricted"',
        '"--safe-mode"',
        '"--strict-mcp-config"',
        '"--setting-sources"',
        '"--json-schema"',
        '"--no-session-persistence"',
        '"WebFetch"',
        '"WebSearch"',
        "validateToolResults",
        "pendingFetches",
    ):
        require(token in text, f"transport missing {token}")
    require('static let emptyMCPConfig = #"{\"mcpServers\":{}}"#' in text, "MCP is not empty")
    require('"FAL_KEY"' not in text, "generation provider credential entered research transport")
    require('"RUNWAYML_API_SECRET"' not in text, "generation provider credential entered transport")
    require('"ANTHROPIC_' not in text, "Anthropic API-key fallback entered research transport")
    require('"CLAUDE_CODE_OAUTH_TOKEN"' not in text, "OAuth token entered research transport")


def validate_html() -> None:
    text = HTML_SPEC.read_text()
    require('<section id="spec">' in text, "missing normative #spec")
    require('<section id="mockups">' in text, "missing mockups")
    require(text.index('id="spec"') < text.index('id="mockups"'), "mock precedes normative spec")
    for phrase in (
        "Research specs with Claude",
        "WebSearch",
        "WebFetch",
        "Application Support",
        "Accept 2 proven fields",
        "Native implementation requires separate owner approval",
    ):
        require(phrase in text, f"HTML omits {phrase}")


def validate_model_owner_registry() -> None:
    corpus = json.loads(CORPUS_JSON.read_text())
    corpus_families = {
        entry["family_id"]
        for entry in corpus["inventory"]
        if entry.get("family_id") is not None
    }
    text = RESEARCH_SCHEMA_SWIFT.read_text()
    block = text.split("static let modelOwnerHosts", 1)[1].split(
        "static func permits", 1
    )[0]
    registered = set(re.findall(r'^\s*"([a-z0-9-]+)":', block, re.MULTILINE))
    require(
        corpus_families <= registered,
        f"owner hosts missing for {sorted(corpus_families - registered)}",
    )
    for host in (
        "ai.google.dev",
        "aistudio.google.com",
        "generativelanguage.googleapis.com",
    ):
        require(host in block, f"Google owner host missing: {host}")


class ModelCapabilityResearchStaticTests(unittest.TestCase):
    def test_image_video_and_music_candidates_are_closed_and_primary(self):
        ids = registered_field_ids()
        fixtures = sorted(FIXTURES.glob("*.json"))
        candidates = [path for path in fixtures if path.name != "claude-code-init.json"]
        self.assertEqual(len(candidates), 3)
        for fixture in candidates:
            validate_fixture(fixture, ids)

    def test_transport_is_hermetic(self):
        validate_transport()

    def test_normative_html_precedes_mockups(self):
        validate_html()

    def test_model_owner_registry_covers_the_capability_corpus(self):
        validate_model_owner_registry()


if __name__ == "__main__":
    unittest.main()
