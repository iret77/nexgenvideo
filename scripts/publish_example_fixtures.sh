#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <examples-directory> <ghcr-reference-with-tag>" >&2
  exit 2
fi

SOURCE="$1"
REFERENCE="$2"
ORAS_BIN="${ORAS_BIN:-oras}"
GHCR_USERNAME="${NGV_GHCR_USERNAME:-iret77}"
TOKEN_FILE="${NGV_GHCR_TOKEN_FILE:-}"
EXPECTATIONS_FILE="${NGV_FIXTURE_EXPECTATIONS_FILE:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$SOURCE" ]; then
  echo "fixture source is not a directory: $SOURCE" >&2
  exit 2
fi
if [ -z "$TOKEN_FILE" ] || [ ! -f "$TOKEN_FILE" ]; then
  echo "NGV_GHCR_TOKEN_FILE must name a readable GitHub Packages token file" >&2
  exit 2
fi
if [ -z "$EXPECTATIONS_FILE" ] || [ ! -f "$EXPECTATIONS_FILE" ]; then
  echo "NGV_FIXTURE_EXPECTATIONS_FILE must name a readable private expectations file" >&2
  exit 2
fi
if ! command -v "$ORAS_BIN" >/dev/null 2>&1; then
  echo "ORAS CLI is not available: $ORAS_BIN" >&2
  exit 2
fi
case "$REFERENCE" in
  ghcr.io/iret77/nexgenvideo-examples:*@*)
    echo "reference must use a mutable tag for publication, not a digest: $REFERENCE" >&2
    exit 2
    ;;
  ghcr.io/iret77/nexgenvideo-examples:*) ;;
  *) echo "reference must be a tag in ghcr.io/iret77/nexgenvideo-examples" >&2; exit 2 ;;
esac

WORK="$(mktemp -d /tmp/ngv-example-fixtures.XXXXXX)"
cleanup() {
  case "$WORK" in
    /tmp/ngv-example-fixtures.*) rm -rf "$WORK" ;;
    *) echo "refusing to remove unexpected work directory: $WORK" >&2 ;;
  esac
}
trap cleanup EXIT HUP INT TERM

CREATE_ARGS=(
  create
  --source "$SOURCE"
  --archive "$WORK/examples.tar.gz"
  --manifest "$WORK/fixtures.manifest.json"
  --expectations "$EXPECTATIONS_FILE"
)
python3 "$ROOT/scripts/example_fixture_bundle.py" "${CREATE_ARGS[@]}"
python3 "$ROOT/scripts/example_fixture_bundle.py" check-repository \
  --repository "$ROOT" \
  --manifest "$WORK/fixtures.manifest.json"

"$ORAS_BIN" login ghcr.io \
  --username "$GHCR_USERNAME" \
  --password-stdin \
  --registry-config "$WORK/registry.json" < "$TOKEN_FILE"

DIGEST="$({
  cd "$WORK"
  "$ORAS_BIN" push \
    --no-tty \
    --registry-config "$WORK/registry.json" \
    --artifact-type application/vnd.nexgenvideo.example-fixtures.v2 \
    --format 'go-template={{.digest}}' \
    "$REFERENCE" \
    examples.tar.gz:application/vnd.nexgenvideo.example-fixtures.v2.tar+gzip \
    fixtures.manifest.json:application/vnd.nexgenvideo.example-fixtures.manifest.v2+json
})"
printf '%s@%s\n' "${REFERENCE%:*}" "$DIGEST"
