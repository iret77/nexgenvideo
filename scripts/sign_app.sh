#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "usage: $0 APP MODE BPY_BUNDLE_MODE SIGN_IDENTITY" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
MODE="$2"
BPY_BUNDLE_MODE="$3"
SIGN_IDENTITY="$4"

case "$BPY_BUNDLE_MODE" in
  full|boundary|omitted) ;;
  *) echo "unknown bpy bundle mode: $BPY_BUNDLE_MODE" >&2; exit 1 ;;
esac
if [ "$BPY_BUNDLE_MODE" != "full" ] && [ "$MODE" != "dev" ]; then
  echo "alternate bpy bundle modes are valid only for CI dev bundles" >&2
  exit 1
fi

case "$MODE" in
  dev) SIGN_OPTIONS=(--force --sign -) ;;
  fast)
    [ -n "$SIGN_IDENTITY" ] || { echo "fast signing requires a stable identity" >&2; exit 1; }
    SIGN_OPTIONS=(--force --sign "$SIGN_IDENTITY")
    ;;
  distribution)
    [ -n "$SIGN_IDENTITY" ] || { echo "distribution signing requires a Developer ID identity" >&2; exit 1; }
    SIGN_OPTIONS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
    ;;
  *) echo "unknown signing mode: $MODE" >&2; exit 1 ;;
esac

if [ "$BPY_BUNDLE_MODE" != "omitted" ]; then
  codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/NexGenVideoBpyStorage"
  BPY_FIRST="$APP/Contents/XPCServices/NexGenVideoBpyService0.xpc"
  BPY_SECOND="$APP/Contents/XPCServices/NexGenVideoBpyService1.xpc"
  if [ "$BPY_BUNDLE_MODE" = "full" ]; then
    python3 "$ROOT/scripts/bpy_bundle_layout.py" compare "$APP"
    if [ -e "$APP/Contents/Resources/BpyRuntimeCompliance/runtime-tree-manifest.json" ]; then
      python3 "$ROOT/scripts/bpy_bundle_layout.py" verify "$APP"
    fi
    BPY_RUNTIME="$BPY_FIRST/Contents/Resources/BpyRuntime"
    BPY_COPY="$BPY_SECOND/Contents/Resources/BpyRuntime"
    echo "==> Codesigning managed bpy runtime"
    while IFS= read -r -d '' binary; do
      [ "$binary" = "$BPY_RUNTIME/python/bin/python3.13" ] && continue
      description="$(file --brief "$binary")"
      if [[ "$description" == *Mach-O* ]]; then
        codesign "${SIGN_OPTIONS[@]}" "$binary"
        cp "$binary" "$BPY_COPY/${binary#"$BPY_RUNTIME/"}"
      fi
    done < <(find "$BPY_RUNTIME" -depth -type f -print0)
    codesign "${SIGN_OPTIONS[@]}" \
      --entitlements "$ROOT/Runtime/bpy/PythonChild.entitlements" \
      "$BPY_RUNTIME/python/bin/python3.13"
    cp "$BPY_RUNTIME/python/bin/python3.13" "$BPY_COPY/python/bin/python3.13"
    python3 "$ROOT/scripts/bpy_bundle_layout.py" seal "$APP"
  fi
  codesign "${SIGN_OPTIONS[@]}" \
    --entitlements "$ROOT/Runtime/bpy/PythonChild.entitlements" \
    "$BPY_FIRST/Contents/MacOS/NexGenVideoBpySupervisor"
  cp "$BPY_FIRST/Contents/MacOS/NexGenVideoBpySupervisor" "$BPY_SECOND/Contents/MacOS/NexGenVideoBpySupervisor"
  for slot in 0 1; do
    BPY_XPC="$APP/Contents/XPCServices/NexGenVideoBpyService$slot.xpc"
    codesign "${SIGN_OPTIONS[@]}" \
      --entitlements "$ROOT/Runtime/bpy/NexGenVideoBpyService.entitlements" \
      "$BPY_XPC/Contents/MacOS/NexGenVideoBpyService"
    codesign "${SIGN_OPTIONS[@]}" \
      --entitlements "$ROOT/Runtime/bpy/NexGenVideoBpyService.entitlements" \
      "$BPY_XPC"
    if [ "$MODE" = "distribution" ]; then
      codesign --verify --strict --verbose=2 "$BPY_XPC"
    fi
  done
fi

SPARKLE_CURRENT="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
if [ -d "$SPARKLE_CURRENT" ]; then
  echo "==> Codesigning nested Sparkle helpers"
  for helper in \
      "$SPARKLE_CURRENT/Autoupdate" \
      "$SPARKLE_CURRENT/Updater.app/Contents/MacOS/Updater" \
      "$SPARKLE_CURRENT/Updater.app" \
      "$SPARKLE_CURRENT/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
      "$SPARKLE_CURRENT/XPCServices/Downloader.xpc" \
      "$SPARKLE_CURRENT/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
      "$SPARKLE_CURRENT/XPCServices/Installer.xpc"; do
    if [ -e "$helper" ]; then
      codesign "${SIGN_OPTIONS[@]}" "$helper"
    fi
  done
fi

for framework in "$APP/Contents/Frameworks"/*.framework; do
  [ -d "$framework" ] || continue
  echo "==> Codesigning embedded framework $(basename "$framework")"
  codesign "${SIGN_OPTIONS[@]}" "$framework"
done
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
  [ -f "$dylib" ] || continue
  echo "==> Codesigning embedded library $(basename "$dylib")"
  codesign "${SIGN_OPTIONS[@]}" "$dylib"
done

echo "==> Codesigning main app"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/NexGenVideoDiagnostics"
if [ "$MODE" = "distribution" ]; then
  codesign "${SIGN_OPTIONS[@]}" --entitlements "$ROOT/scripts/NexGenVideo.entitlements" "$APP"
else
  codesign "${SIGN_OPTIONS[@]}" "$APP"
fi
if [ "$MODE" != "fast" ]; then
  codesign --verify --strict --verbose=2 "$APP"
fi
