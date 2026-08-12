#!/bin/bash
set -euo pipefail

DESTINATION="${1:?runtime destination required}"
shift

consumers=()
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
  consumers+=("$1")
  shift
done
if [ "$#" -eq 0 ]; then
  echo "!! separate consumers from artifact roots with --" >&2
  exit 1
fi
shift
roots=("$@")

if [ "${#consumers[@]}" -eq 0 ]; then
  echo "!! at least one runtime consumer is required" >&2
  exit 1
fi
if [ "${#roots[@]}" -eq 0 ]; then
  echo "!! at least one artifact root is required" >&2
  exit 1
fi
destination_parent="$(dirname "$DESTINATION")"
case "$(basename "$DESTINATION")" in
  Frameworks|PackageFrameworks) ;;
  *) echo "!! runtime destination must be a Frameworks directory: $DESTINATION" >&2; exit 1 ;;
esac
if [ "$destination_parent" = "/" ] || [ ! -d "$destination_parent" ]; then
  echo "!! runtime destination requires an existing, non-root parent: $DESTINATION" >&2
  exit 1
fi

XCRUN="${NGV_XCRUN:-xcrun}"
if ! command -v "$XCRUN" >/dev/null 2>&1; then
  echo "!! xcrun is required to inspect runtime dependencies" >&2
  exit 1
fi
for tool in otool vtool; do
  if ! "$XCRUN" --find "$tool" >/dev/null 2>&1; then
    echo "!! Xcode tool is unavailable: $tool" >&2
    exit 1
  fi
done

for consumer in "${consumers[@]}"; do
  case "$consumer" in
    "$DESTINATION"/*)
      echo "!! runtime consumer cannot be inside the staging destination: $consumer" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$consumer" ]; then
    echo "!! runtime consumer does not exist: $consumer" >&2
    exit 1
  fi
done

for root in "${roots[@]}"; do
  if [ ! -d "$root" ]; then
    echo "!! artifact root does not exist: $root" >&2
    exit 1
  fi
done

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"

worklist=()
enqueue() {
  local candidate="$1"
  local seen
  if [ "${#worklist[@]}" -gt 0 ]; then
    for seen in "${worklist[@]}"; do
      [ "$seen" = "$candidate" ] && return
    done
  fi
  worklist+=("$candidate")
}

is_macos_arm64() {
  local binary="$1"
  "$XCRUN" vtool -arch arm64 -show-build "$binary" 2>/dev/null \
    | grep -qE 'platform[[:space:]]+MACOS' || return 1
}

resolve_framework() {
  local framework="$1"
  local executable="$2"
  local selected=""
  local match_count=0
  local root candidate binary
  for root in "${roots[@]}"; do
    selected=""
    match_count=0
    while IFS= read -r candidate; do
      binary="$candidate/$executable"
      [ -f "$binary" ] || continue
      is_macos_arm64 "$binary" || continue
      selected="$candidate"
      match_count=$((match_count + 1))
    done < <(
      find "$root" -path "$DESTINATION" -prune -o \
        -type d -name "$framework" -print -prune
    )
    if [ "$match_count" -gt 1 ]; then
      echo "!! ambiguous macOS arm64 artifact for @rpath/$framework/$executable in $root ($match_count matches)" >&2
      exit 1
    fi
    if [ "$match_count" -eq 1 ]; then
      cp -R "$selected" "$DESTINATION/$framework"
      return
    fi
  done
  echo "!! no declared macOS arm64 artifact provides @rpath/$framework/$executable" >&2
  exit 1
}

resolve_dylib() {
  local relative="$1"
  local selected=""
  local match_count=0
  local filename
  local root candidate
  filename="$(basename "$relative")"
  for root in "${roots[@]}"; do
    selected=""
    match_count=0
    while IFS= read -r candidate; do
      is_macos_arm64 "$candidate" || continue
      selected="$candidate"
      match_count=$((match_count + 1))
    done < <(find "$root" -path "$DESTINATION" -prune -o -type f -name "$filename" -print)
    if [ "$match_count" -gt 1 ]; then
      echo "!! ambiguous macOS arm64 artifact for @rpath/$relative in $root ($match_count matches)" >&2
      exit 1
    fi
    if [ "$match_count" -eq 1 ]; then
      mkdir -p "$(dirname "$DESTINATION/$relative")"
      cp "$selected" "$DESTINATION/$relative"
      return
    fi
  done
  echo "!! no declared macOS arm64 artifact provides @rpath/$relative" >&2
  exit 1
}

for consumer in "${consumers[@]}"; do
  enqueue "$consumer"
done

index=0
dependency_count=0
while [ "$index" -lt "${#worklist[@]}" ]; do
  consumer="${worklist[$index]}"
  index=$((index + 1))
  dependencies="$(
    "$XCRUN" otool -L "$consumer" \
      | sed -n -E 's/^[[:space:]]*(@rpath\/.*)[[:space:]]+\(compatibility version .*$/\1/p' \
      | LC_ALL=C sort -u
  )"
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    relative="${dependency#@rpath/}"
    case "$relative" in
      *.framework/*)
        framework="${relative%%/*}"
        executable="${relative#*/}"
        if [ ! -f "$DESTINATION/$relative" ]; then
          resolve_framework "$framework" "$executable"
        fi
        if [ ! -f "$DESTINATION/$relative" ]; then
          echo "!! failed to stage $dependency in $DESTINATION" >&2
          exit 1
        fi
        enqueue "$DESTINATION/$relative"
        ;;
      *.dylib)
        if [ ! -f "$DESTINATION/$relative" ]; then
          resolve_dylib "$relative"
        fi
        if [ ! -f "$DESTINATION/$relative" ]; then
          echo "!! failed to stage $dependency in $DESTINATION" >&2
          exit 1
        fi
        enqueue "$DESTINATION/$relative"
        ;;
      *)
        echo "!! unsupported @rpath dependency declared by $consumer: $dependency" >&2
        exit 1
        ;;
    esac
    dependency_count=$((dependency_count + 1))
  done <<EOF
$dependencies
EOF
done

if [ "$dependency_count" -eq 0 ]; then
  echo "!! runtime consumers declare no @rpath dependencies" >&2
  exit 1
fi
