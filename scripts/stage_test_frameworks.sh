#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIRECTORY="${1:?SwiftPM binary directory required}"
CONSUMER="${2:?test consumer binary required}"
shift 2

roots=("$BIN_DIRECTORY")
if [ "$#" -gt 0 ]; then
  roots+=("$@")
else
  roots+=("$ROOT/Vendor" "$ROOT/.build/artifacts")
fi

exec "$ROOT/scripts/stage_runtime_dependencies.sh" \
  "$BIN_DIRECTORY/PackageFrameworks" \
  "$CONSUMER" \
  -- \
  "${roots[@]}"
