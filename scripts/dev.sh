#!/bin/bash
# scripts/dev.sh — build the debug bundle, launch it, and stream its OSLog.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

stream=true
for arg in "$@"; do
    case "$arg" in
        --no-stream) stream=false ;;
    esac
done

"$ROOT/scripts/bundle.sh" debug --fast

if ! $stream; then
    open "$ROOT/.build/NexGenVideo.app"
    exit 0
fi

echo "Streaming OSLog (subsystem=de.h5ventures.nexgenvideo). Ctrl-C to quit app and stop." >&2
echo >&2

cleanup() {
    pid=$(pgrep -f "NexGenVideo.app/Contents/MacOS/NexGenVideo" | head -1 || true)
    if [ -n "$pid" ]; then
        osascript -e 'quit app "NexGenVideo"' 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

( sleep 0.5 && open "$ROOT/.build/NexGenVideo.app" ) &
log stream \
    --predicate 'subsystem == "de.h5ventures.nexgenvideo"' \
    --level info \
    --style compact
