#!/bin/bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "!! test runtime configuration must be debug or release" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="${NGV_SWIFT:-swift}"
VENDOR_ARTIFACT_ROOT="${NGV_VENDOR_ARTIFACT_ROOT:-$ROOT/Vendor}"
SWIFTPM_ARTIFACT_ROOT="${NGV_SWIFTPM_ARTIFACT_ROOT:-$ROOT/.build/artifacts}"
if ! command -v "$SWIFT" >/dev/null 2>&1; then
  echo "!! swift is required to locate built test products" >&2
  exit 1
fi
BIN_DIRECTORY="$("$SWIFT" build -c "$CONFIGURATION" --show-bin-path)"
RESOURCE_BUNDLE="$BIN_DIRECTORY/NexGenVideo_NexGenVideo.bundle"

if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "!! SwiftPM resource bundle does not exist: $RESOURCE_BUNDLE" >&2
  exit 1
fi

consumers=()
for bundle in "$BIN_DIRECTORY"/*.xctest; do
  [ -d "$bundle" ] || continue
  name="$(basename "$bundle" .xctest)"
  consumer="$bundle/Contents/MacOS/$name"
  if [ ! -f "$consumer" ]; then
    echo "!! test bundle executable does not exist: $consumer" >&2
    exit 1
  fi
  consumers+=("$consumer")
done
if [ "${#consumers[@]}" -eq 0 ]; then
  echo "!! no built test bundles found in $BIN_DIRECTORY" >&2
  exit 1
fi

"$ROOT/scripts/compile_metal_resources.sh" "$ROOT/Metal" "$RESOURCE_BUNDLE"
"$ROOT/scripts/stage_runtime_dependencies.sh" \
  "$BIN_DIRECTORY/PackageFrameworks" \
  "${consumers[@]}" \
  -- \
  "$BIN_DIRECTORY" \
  "$VENDOR_ARTIFACT_ROOT" \
  "$SWIFTPM_ARTIFACT_ROOT"
