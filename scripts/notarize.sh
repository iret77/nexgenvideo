#!/bin/bash
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: scripts/notarize.sh <artifact>" >&2; exit 2; }

if [ "${NGV_COMPONENT_NOTARY_CONTINUATION:-}" = true ] && [ "$(basename "$1")" = NexGenVideo.zip ]; then
  exec python3 "$(dirname "$0")/notary_continuation.py" "$1"
fi

exec python3 "$(dirname "$0")/notary_submission.py" "$1"
