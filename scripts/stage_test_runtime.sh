#!/bin/bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
  debug|release) ;;
  *) echo "!! test runtime configuration must be debug or release" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT="${NGV_SWIFT:-swift}"
XCRUN="${NGV_XCRUN:-xcrun}"
VENDOR_ARTIFACT_ROOT="${NGV_VENDOR_ARTIFACT_ROOT:-$ROOT/Vendor}"
SWIFTPM_ARTIFACT_ROOT="${NGV_SWIFTPM_ARTIFACT_ROOT:-$ROOT/.build/artifacts}"
if ! command -v "$SWIFT" >/dev/null 2>&1; then
  echo "!! swift is required to locate built test products" >&2
  exit 1
fi
if ! command -v "$XCRUN" >/dev/null 2>&1; then
  echo "!! xcrun is required to locate the active Swift runtime" >&2
  exit 1
fi

SWIFT_RUNTIME_ROOT="${NGV_SWIFT_RUNTIME_ROOT:-}"
if [ -z "$SWIFT_RUNTIME_ROOT" ]; then
  SWIFT_EXECUTABLE="$("$XCRUN" --find swift)"
  SWIFT_RUNTIME_ROOT="$(cd "$(dirname "$SWIFT_EXECUTABLE")/../lib/swift/macosx" && pwd)"
fi
if [ ! -d "$SWIFT_RUNTIME_ROOT" ]; then
  echo "!! active Swift runtime root does not exist: $SWIFT_RUNTIME_ROOT" >&2
  exit 1
fi

PLATFORM_FRAMEWORK_ROOT="${NGV_PLATFORM_FRAMEWORK_ROOT:-}"
PLATFORM_PRIVATE_FRAMEWORK_ROOT="${NGV_PLATFORM_PRIVATE_FRAMEWORK_ROOT:-}"
PLATFORM_LIBRARY_ROOT="${NGV_PLATFORM_LIBRARY_ROOT:-}"
XCODE_SHARED_FRAMEWORK_ROOT="${NGV_XCODE_SHARED_FRAMEWORK_ROOT:-}"
if [ -z "$PLATFORM_FRAMEWORK_ROOT" ] \
  || [ -z "$PLATFORM_PRIVATE_FRAMEWORK_ROOT" ] \
  || [ -z "$PLATFORM_LIBRARY_ROOT" ] \
  || [ -z "$XCODE_SHARED_FRAMEWORK_ROOT" ]; then
  SDK_PLATFORM_ROOT="$("$XCRUN" --sdk macosx --show-sdk-platform-path)"
  XCODEBUILD_EXECUTABLE="$("$XCRUN" --find xcodebuild)"
  XCODE_DEVELOPER_ROOT="$(cd "$(dirname "$XCODEBUILD_EXECUTABLE")/../.." && pwd -P)"
  [ -n "$PLATFORM_FRAMEWORK_ROOT" ] \
    || PLATFORM_FRAMEWORK_ROOT="$SDK_PLATFORM_ROOT/Developer/Library/Frameworks"
  [ -n "$PLATFORM_PRIVATE_FRAMEWORK_ROOT" ] \
    || PLATFORM_PRIVATE_FRAMEWORK_ROOT="$SDK_PLATFORM_ROOT/Developer/Library/PrivateFrameworks"
  [ -n "$PLATFORM_LIBRARY_ROOT" ] \
    || PLATFORM_LIBRARY_ROOT="$SDK_PLATFORM_ROOT/Developer/usr/lib"
  [ -n "$XCODE_SHARED_FRAMEWORK_ROOT" ] \
    || XCODE_SHARED_FRAMEWORK_ROOT="$(dirname "$XCODE_DEVELOPER_ROOT")/SharedFrameworks"
fi
if [ ! -d "$PLATFORM_FRAMEWORK_ROOT" ]; then
  echo "!! active macOS platform framework root does not exist: $PLATFORM_FRAMEWORK_ROOT" >&2
  exit 1
fi
if [ ! -d "$PLATFORM_PRIVATE_FRAMEWORK_ROOT" ]; then
  echo "!! active macOS platform private framework root does not exist: $PLATFORM_PRIVATE_FRAMEWORK_ROOT" >&2
  exit 1
fi
if [ ! -d "$PLATFORM_LIBRARY_ROOT" ]; then
  echo "!! active macOS platform library root does not exist: $PLATFORM_LIBRARY_ROOT" >&2
  exit 1
fi
if [ ! -d "$XCODE_SHARED_FRAMEWORK_ROOT" ]; then
  echo "!! active Xcode shared framework root does not exist: $XCODE_SHARED_FRAMEWORK_ROOT" >&2
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
  "$SWIFTPM_ARTIFACT_ROOT" \
  "$SWIFT_RUNTIME_ROOT" \
  "$PLATFORM_FRAMEWORK_ROOT" \
  "$PLATFORM_PRIVATE_FRAMEWORK_ROOT" \
  "$PLATFORM_LIBRARY_ROOT" \
  "$XCODE_SHARED_FRAMEWORK_ROOT"
