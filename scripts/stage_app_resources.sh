#!/bin/bash
set -euo pipefail

SOURCE_ROOT="${1:?application resource source required}"
BUILD_BUNDLE="${2:?SwiftPM resource bundle required}"
DESTINATION="${3:?application resource destination required}"

mkdir -p "$DESTINATION"

MANIFEST="$SOURCE_ROOT/AppResources.txt"
if [ ! -f "$MANIFEST" ]; then
  echo "!! missing application resource manifest: $MANIFEST" >&2
  exit 1
fi

resource_count=0
destinations=()
while IFS= read -r entry || [ -n "$entry" ]; do
  entry="${entry%$'\r'}"
  [ -n "$entry" ] || continue
  case "$entry" in
    /*|../*|*/../*|*/..) echo "!! invalid application resource path: $entry" >&2; exit 1 ;;
  esac
  source="$SOURCE_ROOT/$entry"
  if [ ! -e "$source" ]; then
    echo "!! missing required application resource: $source" >&2
    exit 1
  fi
  destination_name="$(basename "$entry")"
  if [ "${#destinations[@]}" -gt 0 ]; then
    for existing_name in "${destinations[@]}"; do
      if [ "$existing_name" = "$destination_name" ]; then
        echo "!! duplicate application resource destination: $destination_name" >&2
        exit 1
      fi
    done
  fi
  destinations+=("$destination_name")
  target="$DESTINATION/$destination_name"
  rm -rf "$target"
  cp -R "$source" "$target"
  resource_count=$((resource_count + 1))
done < "$MANIFEST"
if [ "$resource_count" -eq 0 ]; then
  echo "!! application resource manifest is empty: $MANIFEST" >&2
  exit 1
fi

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
