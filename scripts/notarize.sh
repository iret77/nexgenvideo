#!/bin/bash
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: scripts/notarize.sh <artifact>" >&2; exit 2; }

ARTIFACT="$1"
ATTEMPTS="${NOTARY_ATTEMPTS:-3}"
RETRY_DELAY="${NOTARY_RETRY_DELAY_SECONDS:-5}"

[ -f "$ARTIFACT" ] || { echo "!! artifact not found: $ARTIFACT" >&2; exit 1; }
[ -n "${NOTARY_KEY_FILE:-}" ] || { echo "!! NOTARY_KEY_FILE is required" >&2; exit 1; }
[ -n "${NOTARY_KEY_ID:-}" ] || { echo "!! NOTARY_KEY_ID is required" >&2; exit 1; }
[ -n "${NOTARY_ISSUER:-}" ] || { echo "!! NOTARY_ISSUER is required" >&2; exit 1; }
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo "!! NOTARY_ATTEMPTS must be a positive integer" >&2; exit 1; }
[[ "$RETRY_DELAY" =~ ^[0-9]+$ ]] || { echo "!! NOTARY_RETRY_DELAY_SECONDS must be a non-negative integer" >&2; exit 1; }

OUTPUT="$(mktemp)"
trap 'rm -f "$OUTPUT"' EXIT

notarytool() {
  if [ -n "${NOTARYTOOL_BIN:-}" ]; then
    "$NOTARYTOOL_BIN" "$@"
  else
    xcrun notarytool "$@"
  fi
}

retry_notarytool() {
  local operation="$1"
  shift
  local attempt exit_code

  for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    : > "$OUTPUT"
    set +e
    notarytool "$@" 2>&1 | tee "$OUTPUT"
    exit_code="${PIPESTATUS[0]}"
    set -e
    if [ "$exit_code" -eq 0 ]; then
      return 0
    fi
    if [ "$attempt" -eq "$ATTEMPTS" ]; then
      echo "!! $operation failed after $ATTEMPTS attempts (exit $exit_code)" >&2
      return "$exit_code"
    fi
    echo "!! $operation failed on attempt $attempt (exit $exit_code); retrying" >&2
    sleep $((RETRY_DELAY * attempt))
  done
}

credentials=(
  --key "$NOTARY_KEY_FILE"
  --key-id "$NOTARY_KEY_ID"
  --issuer "$NOTARY_ISSUER"
  --output-format json
)

JOURNAL=""
if [ -n "${NOTARY_STATE_DIR:-}" ]; then
  mkdir -p "$NOTARY_STATE_DIR"
  ARTIFACT_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
  JOURNAL="$NOTARY_STATE_DIR/$ARTIFACT_SHA.json"
fi
if [ -n "$JOURNAL" ] && [ -f "$JOURNAL" ]; then
  SUBMISSION_ID="$(python3 - "$JOURNAL" "$ARTIFACT_SHA" "${GITHUB_SHA:-}" <<'PY'
import json
import sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
if receipt.get("schema") != "release-notary/v1" or receipt.get("sha256") != sys.argv[2] or receipt.get("sourceSHA") != sys.argv[3]:
    raise SystemExit("notary receipt belongs to another payload or source")
print(receipt.get("submissionID", ""))
PY
)"
else
  retry_notarytool "notary upload" submit "$ARTIFACT" "${credentials[@]}"
  SUBMISSION_ID="$(python3 - "$OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("id", ""))
PY
)"
fi
[[ "$SUBMISSION_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
  || { echo "!! notary upload returned no valid submission ID" >&2; exit 1; }

if [ -n "$JOURNAL" ]; then
  python3 - "$JOURNAL" "$ARTIFACT_SHA" "$SUBMISSION_ID" "${GITHUB_SHA:-}" <<'PY'
import json
import os
from pathlib import Path
import sys
path = Path(sys.argv[1])
temporary = path.with_suffix(".pending")
temporary.write_text(json.dumps({"schema": "release-notary/v1", "sha256": sys.argv[2],
    "submissionID": sys.argv[3], "sourceSHA": sys.argv[4]}, indent=2) + "\n")
os.replace(temporary, path)
PY
fi

if ! retry_notarytool "notary wait for $SUBMISSION_ID" wait "$SUBMISSION_ID" "${credentials[@]}"; then
  notarytool log "$SUBMISSION_ID" "${credentials[@]}" || true
  exit 1
fi

STATUS="$(python3 - "$OUTPUT" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("status", ""))
PY
)"
if [ "$STATUS" != "Accepted" ]; then
  echo "!! notarization $SUBMISSION_ID finished with status: ${STATUS:-unknown}" >&2
  notarytool log "$SUBMISSION_ID" "${credentials[@]}" || true
  exit 1
fi

echo "==> Notarization accepted: $SUBMISSION_ID"
