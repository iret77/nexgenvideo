#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="${1:?staged bpy runtime required}"
SERVICE_BINARY="${2:?bpy XPC service binary required}"
APP="${3:?NexGenVideo app destination required}"

test -f "$RUNTIME_ROOT/.complete"
test -x "$RUNTIME_ROOT/python/bin/python3"
test -f "$RUNTIME_ROOT/site-packages/bpy/__init__.py"
test -x "$SERVICE_BINARY"
case "$APP" in
  *.app) ;;
  *) echo "invalid bpy app destination: $APP" >&2; exit 1 ;;
esac

DESTINATION="$APP/Contents/Helpers/BpyRuntime"
rm -rf "$DESTINATION"
mkdir -p "$DESTINATION"
cp -R "$RUNTIME_ROOT/." "$DESTINATION/"
cp "$ROOT/Runtime/bpy/worker.py" "$DESTINATION/worker.py"
chmod 755 "$DESTINATION/python/bin/python3"*

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

test ! -e "$DESTINATION/python/bin/pip"
test ! -e "$DESTINATION/python/bin/pip3"
