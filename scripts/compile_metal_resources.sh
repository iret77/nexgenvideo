#!/bin/bash
set -euo pipefail

SOURCE_DIRECTORY="${1:?Metal source directory required}"
DESTINATION="${2:?Metal resource destination required}"
XCRUN="${NGV_XCRUN:-xcrun}"

if [ ! -d "$SOURCE_DIRECTORY" ]; then
  echo "!! missing Metal source directory: $SOURCE_DIRECTORY" >&2
  exit 1
fi
if ! command -v "$XCRUN" >/dev/null 2>&1; then
  echo "!! xcrun is required to compile Metal resources" >&2
  exit 1
fi
if ! "$XCRUN" --find metal >/dev/null 2>&1 \
  || ! "$XCRUN" --find metallib >/dev/null 2>&1; then
  echo "!! the Xcode Metal toolchain is unavailable" >&2
  exit 1
fi

if [ ! -d "$DESTINATION" ]; then
  echo "!! Metal resource destination does not exist: $DESTINATION" >&2
  exit 1
fi

destination_parent="$(dirname "$DESTINATION")"
staging="$(mktemp -d "$destination_parent/.ngv-metal.XXXXXX")"
cleanup() {
  rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

source_count=0
for source in "$SOURCE_DIRECTORY"/*.metal; do
  [ -f "$source" ] || continue
  stem="$(basename "$source" .metal)"
  air="$staging/$stem.air"
  metallib="$staging/$stem.metallib"
  "$XCRUN" metal -c -fcikernel "$source" -o "$air"
  "$XCRUN" metallib -cikernel "$air" -o "$metallib"
  rm -f "$air"
  if [ ! -f "$metallib" ]; then
    echo "!! Metal compiler did not produce $metallib" >&2
    exit 1
  fi
  source_count=$((source_count + 1))
done

if [ "$source_count" -eq 0 ]; then
  echo "!! no .metal sources found in $SOURCE_DIRECTORY" >&2
  exit 1
fi

output_count=0
for output in "$staging"/*.metallib; do
  [ -f "$output" ] || continue
  output_count=$((output_count + 1))
done
if [ "$output_count" -ne "$source_count" ]; then
  echo "!! expected $source_count Metal libraries, compiler produced $output_count" >&2
  exit 1
fi

expected=()
for output in "$staging"/*.metallib; do
  name="$(basename "$output")"
  expected+=("$name")
  mv "$output" "$DESTINATION/$name"
done
for output in "$DESTINATION"/*.metallib; do
  [ -f "$output" ] || continue
  name="$(basename "$output")"
  keep=false
  for expected_name in "${expected[@]}"; do
    [ "$expected_name" = "$name" ] && keep=true
  done
  [ "$keep" = true ] || rm -f "$output"
done
