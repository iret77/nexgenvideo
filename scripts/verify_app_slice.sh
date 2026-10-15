#!/bin/bash
# Usage: verify_app_slice.sh <NexGenVideo.app>
set -euo pipefail

APP="${1:?usage: verify_app_slice.sh <NexGenVideo.app>}"
EXPECTED_ARCHS="arm64"
EXPECTED_MINOS="26.0"

status=0
for binary in "$APP/Contents/MacOS/NexGenVideo" "$APP/Contents/Frameworks/libNexGenEngine.dylib"; do
  lipo -info "$binary"
  archs="$(lipo -archs "$binary")"
  minos="$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')"
  echo "$binary: archs=$archs minos=$minos"
  if [ "$archs" != "$EXPECTED_ARCHS" ]; then
    echo "::error::$binary has architectures '$archs', expected '$EXPECTED_ARCHS'"
    status=1
  fi
  if [ "$minos" != "$EXPECTED_MINOS" ]; then
    echo "::error::$binary has minimum macOS '$minos', expected '$EXPECTED_MINOS'"
    status=1
  fi
done
exit "$status"
