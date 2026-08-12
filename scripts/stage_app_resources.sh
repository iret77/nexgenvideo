#!/bin/bash
set -euo pipefail

SOURCE_ROOT="${1:?application resource source required}"
BUILD_BUNDLE="${2:?SwiftPM resource bundle required}"
DESTINATION="${3:?application resource destination required}"

mkdir -p "$DESTINATION"

for directory in Fonts Images Changelog; do
  source="$SOURCE_ROOT/$directory"
  if [ ! -d "$source" ]; then
    echo "!! missing required application resource directory: $source" >&2
    exit 1
  fi
  cp -R "$source" "$DESTINATION/"
done

MCP_BUNDLE="$SOURCE_ROOT/MCPB/nexgen.mcpb"
if [ ! -f "$MCP_BUNDLE" ]; then
  echo "!! missing required application resource: $MCP_BUNDLE" >&2
  exit 1
fi
cp "$MCP_BUNDLE" "$DESTINATION/"

metallib_count=0
for metallib in "$BUILD_BUNDLE"/*.metallib; do
  [ -f "$metallib" ] || continue
  cp "$metallib" "$DESTINATION/"
  metallib_count=$((metallib_count + 1))
done
if [ "$metallib_count" -eq 0 ]; then
  echo "!! no generated .metallib in SwiftPM resource bundle: $BUILD_BUNDLE" >&2
  exit 1
fi
