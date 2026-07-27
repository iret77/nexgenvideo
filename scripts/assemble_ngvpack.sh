#!/bin/bash
set -euo pipefail

# Assemble a loadable format pack into a signed `.ngvpack` bundle + zip and emit
# its catalog entry (sans download URL — release.yml fills that per release).
#
# Usage:
#   scripts/assemble_ngvpack.sh <manifest.json> <config> <out_dir> [sign_identity]
#
#   <manifest.json>  plugins/<id>.json — the pack's static metadata
#   <config>         release | debug (must match an already-built swift build)
#   <out_dir>        where to write <id>.ngvpack, <id>.ngvpack.zip, <id>.entry.json
#   [sign_identity]  Developer ID Application identity; omitted → ad-hoc ("-")
#
# The pack carries: Contents/MacOS/<id> (the plugin dylib, renamed), the SwiftPM
# resource bundle in Contents/Resources (PackKnowledge finds it there), and an
# Info.plist with the NGV gate keys (NGVPackID / CFBundleShortVersionString /
# NGVMinAppVersion / NGVEngineContract / NSPrincipalClass). The plugin dylib keeps its
# @rpath/libNexGenEngine.dylib dependency — dyld dedups it onto the host's copy.

MANIFEST="${1:?manifest.json required}"
CONFIG="${2:-release}"
OUT="${3:-.build/plugins}"
SIGN_ID="${4:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$MANIFEST" ] || { echo "!! manifest not found: $MANIFEST" >&2; exit 1; }

# Read fields from the manifest (python3 ships on the macOS runner).
read_field() { python3 -c "import json,sys;print(json.load(open('$MANIFEST'))['$1'])"; }
# Optional field — empty string when absent (no KeyError).
read_optional() { python3 -c "import json,sys;print(json.load(open('$MANIFEST')).get('$1',''))"; }
ID="$(read_field id)"
TARGET="$(read_field target)"
PRINCIPAL="$(read_field principalClass)"
DISPLAY="$(read_field displayName)"
TAGLINE="$(read_field tagline)"
HEADLINE="$(read_optional headline)"
BENEFIT="$(read_optional benefit)"
VERSION="$(read_field version)"
PROJECT_SCHEMA="$(read_field projectSchema)"
MIGRATES_FROM="$(python3 -c "import json;print(','.join(json.load(open('$MANIFEST')).get('migratesFrom',[])))")"
MINAPP="$(read_field minAppVersion)"
# Badge source, relative to the SwiftPM resource bundle (e.g. MusicvideoPack/badge.png).
BADGE_SRC="$(read_optional badge)"

# The host↔pack binary contract, BAKED into the bundle. Read from the engine SOURCE this pack was
# built against — never from the engine at runtime: the pack links libNexGenEngine.dylib, so at load
# time it would report the HOST's value and the check would always pass. No default: an unreadable
# constant must fail the build, not silently stamp a pack that later reads as contract 0.
CONTRACT_SRC="$ROOT/Engine/Sources/NexGenEngine/Packs/EngineContract.swift"
[ -f "$CONTRACT_SRC" ] || { echo "!! missing engine contract source: $CONTRACT_SRC" >&2; exit 1; }
# `|| true` so a no-match reaches the explicit check below with its message, rather than
# aborting silently on `set -e` + `pipefail`.
CONTRACT="$(grep -Eo '^[[:space:]]*public static let current = [0-9]+[[:space:]]*$' "$CONTRACT_SRC" \
  | grep -Eo '[0-9]+' | head -1 || true)"
[ -n "$CONTRACT" ] || {
  echo "!! could not read EngineContract.current from $CONTRACT_SRC" >&2
  echo "   expected a line exactly like: public static let current = <int>" >&2
  exit 1
}

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
DYLIB="$BINDIR/lib${TARGET}.dylib"
RES_BUNDLE="$BINDIR/NexGenVideo_${TARGET}.bundle"
[ -f "$DYLIB" ] || { echo "!! missing plugin dylib: $DYLIB (run swift build -c $CONFIG first)" >&2; exit 1; }
[ -d "$RES_BUNDLE" ] || { echo "!! missing plugin resource bundle: $RES_BUNDLE" >&2; exit 1; }

mkdir -p "$OUT"
PACK="$OUT/${ID}.ngvpack"
ZIP="$OUT/${ID}.ngvpack.zip"
rm -rf "$PACK" "$ZIP"
mkdir -p "$PACK/Contents/MacOS" "$PACK/Contents/Resources"

cp "$DYLIB" "$PACK/Contents/MacOS/${ID}"
cp -R "$RES_BUNDLE" "$PACK/Contents/Resources/"

# The pack loads from OUTSIDE the app bundle, so its build-time rpath (@loader_path) can't reach the
# host's shared libNexGenEngine.dylib. @executable_path is ALWAYS the HOST executable's dir for any
# image in the process, so this rpath resolves the pack's @rpath/libNexGenEngine.dylib to the app's
# Contents/Frameworks — the SAME image the host already loaded (dyld dedups → one PackEntry class →
# the load-time `principalClass as? PackEntry.Type` cast succeeds). Without it the pack pulls a second
# engine image and the cast fails ("entry point not found" — the 0.7.6 regression). Must precede codesign.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$PACK/Contents/MacOS/${ID}"

# Info.plist via plistlib — no shell-escaping hazards with the copy strings.
NGV_ID="$ID" NGV_DISPLAY="$DISPLAY" NGV_TAGLINE="$TAGLINE" NGV_HEADLINE="$HEADLINE" \
NGV_BENEFIT="$BENEFIT" NGV_VERSION="$VERSION" NGV_MINAPP="$MINAPP" NGV_PRINCIPAL="$PRINCIPAL" \
NGV_PROJECT_SCHEMA="$PROJECT_SCHEMA" NGV_MIGRATES_FROM="$MIGRATES_FROM" NGV_CONTRACT="$CONTRACT" \
python3 - "$PACK/Contents/Info.plist" <<'PY'
import os, plistlib, sys
info = {
    "CFBundleIdentifier": f"de.h5ventures.nexgenvideo.pack.{os.environ['NGV_ID']}",
    "CFBundleName": os.environ["NGV_DISPLAY"],
    "CFBundleExecutable": os.environ["NGV_ID"],
    "CFBundlePackageType": "BNDL",
    "CFBundleShortVersionString": os.environ["NGV_VERSION"],
    "CFBundleVersion": os.environ["NGV_VERSION"],
    "NSPrincipalClass": os.environ["NGV_PRINCIPAL"],
    "NGVPackID": os.environ["NGV_ID"],
    "NGVPackDisplayName": os.environ["NGV_DISPLAY"],
    "NGVPackTagline": os.environ["NGV_TAGLINE"],
    "NGVPackHeadline": os.environ["NGV_HEADLINE"],
    "NGVPackBenefit": os.environ["NGV_BENEFIT"],
    "NGVProjectSchema": os.environ["NGV_PROJECT_SCHEMA"],
    "NGVMigratesFrom": [value for value in os.environ["NGV_MIGRATES_FROM"].split(",") if value],
    "NGVMinAppVersion": os.environ["NGV_MINAPP"],
    "NGVEngineContract": int(os.environ["NGV_CONTRACT"]),
}
with open(sys.argv[1], "wb") as f:
    plistlib.dump(info, f)
PY

# Sign: Developer ID (hardened runtime + timestamp) when an identity is given,
# else ad-hoc so a signature always exists for the load gate. Sign the inner
# dylib first, then the bundle.
if [ -n "$SIGN_ID" ]; then
  SIGN_OPTS=(--force --options runtime --timestamp --sign "$SIGN_ID")
else
  echo "==> No signing identity — ad-hoc signing $ID.ngvpack"
  SIGN_OPTS=(--force --sign -)
fi
codesign "${SIGN_OPTS[@]}" "$PACK/Contents/MacOS/${ID}"
codesign "${SIGN_OPTS[@]}" "$PACK"
codesign --verify --strict --verbose=2 "$PACK"

# Zip (ditto preserves the bundle structure + resource forks).
/usr/bin/ditto -c -k --keepParent "$PACK" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# Badge: publish the pack's badge art as its own release asset so the catalog can
# show it BEFORE install (the .ngvpack itself isn't downloaded until then). Optional
# — a pack without a `badge` field just gets the gallery's gradient fallback.
BADGE_ASSET=""
if [ -n "$BADGE_SRC" ]; then
  BADGE_FILE="$RES_BUNDLE/$BADGE_SRC"
  if [ -f "$BADGE_FILE" ]; then
    BADGE_ASSET="${ID}.badge.png"
    cp "$BADGE_FILE" "$OUT/$BADGE_ASSET"
    echo "    badge:  $OUT/$BADGE_ASSET"
  else
    echo "!! declared badge not found: $BADGE_FILE — shipping without a catalog badge" >&2
  fi
fi

# Catalog entry (url + badge filled by release.yml/gen_plugins_json for the release).
NGV_ID="$ID" NGV_DISPLAY="$DISPLAY" NGV_TAGLINE="$TAGLINE" NGV_HEADLINE="$HEADLINE" \
NGV_BENEFIT="$BENEFIT" NGV_VERSION="$VERSION" NGV_MINAPP="$MINAPP" NGV_SHA="$SHA" \
NGV_PROJECT_SCHEMA="$PROJECT_SCHEMA" NGV_MIGRATES_FROM="$MIGRATES_FROM" \
NGV_ZIP="$(basename "$ZIP")" NGV_BADGE="$BADGE_ASSET" \
python3 - "$OUT/${ID}.entry.json" <<'PY'
import json, os, sys
entry = {
    "id": os.environ["NGV_ID"],
    "displayName": os.environ["NGV_DISPLAY"],
    "tagline": os.environ["NGV_TAGLINE"],
    "version": os.environ["NGV_VERSION"],
    "projectSchema": os.environ["NGV_PROJECT_SCHEMA"],
    "migratesFrom": [value for value in os.environ["NGV_MIGRATES_FROM"].split(",") if value],
    "minAppVersion": os.environ["NGV_MINAPP"],
    "sha256": os.environ["NGV_SHA"],
    "zip": os.environ["NGV_ZIP"],
}
for key, env in (("headline", "NGV_HEADLINE"), ("benefit", "NGV_BENEFIT")):
    value = os.environ.get(env, "")
    if value:
        entry[key] = value
badge = os.environ.get("NGV_BADGE", "")
if badge:
    entry["badge"] = badge  # filename → gen_plugins_json turns it into a URL
with open(sys.argv[1], "w") as f:
    json.dump(entry, f, indent=2)
PY

echo "==> Assembled $PACK"
echo "    zip:      $ZIP"
echo "    sha256:   $SHA"
echo "    contract: $CONTRACT"
