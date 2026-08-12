#!/bin/bash
set -euo pipefail

BIN_DIRECTORY="${1:?SwiftPM binary directory required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$BIN_DIRECTORY/PackageFrameworks"
WHISPER_FRAMEWORK="$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"

if [ ! -f "$WHISPER_FRAMEWORK/Versions/Current/whisper" ]; then
  echo "!! missing vendored whisper runtime: $WHISPER_FRAMEWORK" >&2
  exit 1
fi

mkdir -p "$DESTINATION"
cp -R "$WHISPER_FRAMEWORK" "$DESTINATION/"

if [ ! -f "$DESTINATION/whisper.framework/Versions/Current/whisper" ]; then
  echo "!! failed to stage whisper runtime in $DESTINATION" >&2
  exit 1
fi
