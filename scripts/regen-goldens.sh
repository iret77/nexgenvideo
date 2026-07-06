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

echo "==> Done. Fixture: $FIXTURE_HOME  Goldens: $GOLDENS_DIR"
