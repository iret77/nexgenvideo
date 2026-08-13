#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIRECTORY="${1:?SwiftPM binary directory required}"
CONSUMER="${2:?test consumer binary required}"
shift 2

macos_directory="$(dirname "$CONSUMER")"
contents_directory="$(dirname "$macos_directory")"
bundle="$(dirname "$contents_directory")"
case "$bundle" in
  "$BIN_DIRECTORY"/*.xctest) ;;
  *) echo "!! test consumer must belong to an .xctest bundle in $BIN_DIRECTORY: $CONSUMER" >&2; exit 1 ;;
esac
if [ "$(basename "$macos_directory")" != "MacOS" ] \
  || [ "$(basename "$contents_directory")" != "Contents" ] \
  || [ ! -f "$CONSUMER" ]; then
  echo "!! invalid .xctest consumer executable: $CONSUMER" >&2
  exit 1
fi

roots=("$BIN_DIRECTORY")
if [ "$#" -gt 0 ]; then
  roots+=("$@")
else
  roots+=("$ROOT/Vendor" "$ROOT/.build/artifacts")
fi

exclude_arguments=()
for sibling_bundle in "$BIN_DIRECTORY"/*.xctest; do
  [ -d "$sibling_bundle" ] || continue
  exclude_arguments+=( --exclude "$sibling_bundle/Contents/Frameworks" )
done

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/nexgenvideo-test-runtime.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
temporary_destination="$staging_root/Frameworks"
final_destination="$contents_directory/Frameworks"

"$ROOT/scripts/stage_runtime_dependencies.sh" \
  "$temporary_destination" \
  "${exclude_arguments[@]}" \
  "$CONSUMER" \
  -- \
  "${roots[@]}"

rm -rf "$final_destination"
mv "$temporary_destination" "$final_destination"
