#!/bin/bash
set -euo pipefail

APP="${1:?NexGenVideo.app required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$APP/Contents/Helpers/BpyRuntime"
PYTHON="$RUNTIME/python/bin/python3.13"

test -x "$PYTHON"
test -f "$RUNTIME/site-packages/bpy/__init__.py"
test -f "$RUNTIME/PYTHON.json"
test ! -e "$RUNTIME/python/bin/pip"
test ! -e "$RUNTIME/python/bin/pip3"
test ! -e "$RUNTIME/python/bin/pip3.13"
cmp -s "$RUNTIME/runtime-lock.json" "$ROOT/Runtime/bpy/runtime-lock.json"
[ "$(cat "$RUNTIME/.complete")" = "$(shasum -a 256 "$ROOT/Runtime/bpy/runtime-lock.json" | awk '{print $1}')" ]

codesign --verify --strict --verbose=2 "$PYTHON"
for slot in 0 1; do
  XPC="$APP/Contents/XPCServices/NexGenVideoBpyService$slot.xpc"
  test -d "$XPC"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$XPC/Contents/Info.plist")" \
    = "de.h5ventures.nexgenvideo.bpy-service-$slot" ]
  codesign --verify --strict --verbose=2 "$XPC"
done

while IFS= read -r -d '' binary; do
  file "$binary" | grep -q 'Mach-O' || continue
  codesign --verify --strict --verbose=2 "$binary"
  arches="$(lipo -archs "$binary")"
  [ "$arches" = "arm64" ] || {
    echo "unexpected architecture in $binary: $arches" >&2
    exit 1
  }
  while IFS= read -r dependency; do
    case "$dependency" in
      @rpath/*|@loader_path/*|@executable_path/*|/usr/lib/*|/System/Library/*) ;;
      *) echo "non-relocatable dependency in $binary: $dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done < <(find "$RUNTIME" "$APP/Contents/XPCServices" -type f -print0)

echo "managed bpy bundle is signed, arm64-only, and relocatable"
