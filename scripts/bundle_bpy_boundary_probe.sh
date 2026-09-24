#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE_BINARY="${1:?bpy XPC service binary required}"
APP="${2:?NexGenVideo app destination required}"
SUPERVISOR_BINARY="$(dirname "$SERVICE_BINARY")/NexGenVideoBpySupervisor"

test -x "$SERVICE_BINARY"
test -x "$SUPERVISOR_BINARY"
case "$APP" in
  *.app) ;;
  *) echo "invalid boundary-probe app destination: $APP" >&2; exit 1 ;;
esac

cp "$SUPERVISOR_BINARY" "$APP/Contents/Helpers/NexGenVideoBpySupervisor"
chmod 755 "$APP/Contents/Helpers/NexGenVideoBpySupervisor"

for slot in 0 1; do
  XPC="$APP/Contents/XPCServices/NexGenVideoBpyService$slot.xpc"
  rm -rf "$XPC"
  mkdir -p "$XPC/Contents/MacOS"
  cp "$SERVICE_BINARY" "$XPC/Contents/MacOS/NexGenVideoBpyService"
  cp "$ROOT/Runtime/bpy/NexGenVideoBpyService-Info.plist" "$XPC/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c \
    "Set :CFBundleIdentifier de.h5ventures.nexgenvideo.bpy-service-$slot" \
    "$XPC/Contents/Info.plist"
  chmod 755 "$XPC/Contents/MacOS/NexGenVideoBpyService"
done

printf '%s\n' \
  'Fixed-input signed boundary probe only; no bpy or Python payload is present.' \
  > "$APP/Contents/Resources/BPY_BOUNDARY_PROBE_NONPRODUCT_CI"
