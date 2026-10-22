#!/bin/bash
set -euo pipefail

APP="${1:?NexGenVideo.app required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$APP/Contents/Resources/BpyRuntime"
PYTHON="$RUNTIME/python/bin/python3.13"
SUPERVISOR="$APP/Contents/Helpers/NexGenVideoBpySupervisor"
STORAGE="$APP/Contents/Helpers/NexGenVideoBpyStorage"
VERIFY_MODE="${2:---distribution}"
case "$VERIFY_MODE" in
  --distribution) python3 "$ROOT/scripts/verify_bpy_signing.py" "$APP" ;;
  --development) python3 "$ROOT/scripts/verify_bpy_signing.py" "$APP" --development ;;
  *) echo "unknown bpy verification mode: $VERIFY_MODE" >&2; exit 1 ;;
esac

test -x "$PYTHON"
test -x "$SUPERVISOR"
test -x "$STORAGE"
BPY_ENTRYPOINT="$(jq -r .bpyWheelLayout.entryPoint "$ROOT/Runtime/bpy/runtime-lock.json")"
test -f "$RUNTIME/site-packages/$BPY_ENTRYPOINT"
test -f "$RUNTIME/PYTHON.json"
test ! -e "$RUNTIME/python/bin/pip"
test ! -e "$RUNTIME/python/bin/pip3"
test ! -e "$RUNTIME/python/bin/pip3.13"
cmp -s "$RUNTIME/runtime-lock.json" "$ROOT/Runtime/bpy/runtime-lock.json"
[ "$(cat "$RUNTIME/.complete")" = "$(shasum -a 256 "$ROOT/Runtime/bpy/runtime-lock.json" | awk '{print $1}')" ]
if [ "$(jq -r .distributionStatus "$ROOT/Runtime/bpy/runtime-lock.json")" = ready ]; then
  while IFS=$'\t' read -r filename sha size; do
    SOURCE="$RUNTIME/corresponding-source/$filename"
    test -f "$SOURCE"
    test "$(shasum -a 256 "$SOURCE" | awk '{print $1}')" = "$sha"
    test "$(stat -f %z "$SOURCE")" = "$size"
  done < <(jq -r '.distributionClosure.sourceArchives[] | [.filename,.sha256,.size] | @tsv' "$ROOT/Runtime/bpy/runtime-lock.json")
  while IFS=$'\t' read -r relative sha; do
    EVIDENCE="$RUNTIME/licenses/distribution/$(basename "$relative")"
    test -f "$EVIDENCE"
    test "$(shasum -a 256 "$EVIDENCE" | awk '{print $1}')" = "$sha"
  done < <(jq -r '[(.distributionClosure.wheelBinaryCorrespondence), (.distributionClosure.noticeCoverage), .distributionClosure.noticeFiles[]] | .[] | [.path,.sha256] | @tsv' "$ROOT/Runtime/bpy/runtime-lock.json")
fi

codesign --verify --strict --verbose=2 "$PYTHON"
codesign --verify --strict --verbose=2 "$SUPERVISOR"
codesign --verify --strict --verbose=2 "$STORAGE"
if codesign -d --entitlements :- "$STORAGE" 2>/dev/null | grep -q 'com.apple.security.\(app-sandbox\|inherit\)'; then
  echo "storage helper must retain the non-sandboxed host's mount authority" >&2
  exit 1
fi
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
done < <(find "$RUNTIME" "$SUPERVISOR" "$STORAGE" "$APP/Contents/XPCServices" -type f -print0)

echo "managed bpy bundle is signed, arm64-only, and relocatable"
