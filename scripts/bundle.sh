#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # stable-identity signing without dSYM
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG
#   scripts/bundle.sh release --package         # notarize + DMG from an existing signed app

CONFIG="release"
MODE="dev"
BPY_BUNDLE_MODE="full"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    --package)     MODE="package" ;;
    --without-bpy-runtime-for-ci-transfer) BPY_BUNDLE_MODE="omitted" ;;
    --bpy-boundary-probe-for-ci-transfer) BPY_BUNDLE_MODE="boundary" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE=".env"
if [ "$CONFIG" = "release" ] && [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE=".env.prod"
fi
if [ -f "$ROOT/$ENV_FILE" ]; then
  echo "==> Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ROOT/$ENV_FILE"
  set +a
fi

# Signing + notarization are env-driven — no hard-coded team. In CI the Developer ID cert is
# imported into a temporary keychain (added to the search list) and SIGN_IDENTITY is auto-detected
# below; notarization uses an App Store Connect API key. Sparkle EdDSA signing of the DMG happens in
# the release workflow (openssl), not here.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_KEY_FILE="${NOTARY_KEY_FILE:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${NOTARY_ISSUER:-}"
SENTRY_DSN="${SENTRY_DSN:-}"
PLUGIN_CATALOG_URL="${PLUGIN_CATALOG_URL:-}"
RESOURCES="$ROOT/Sources/NexGenVideo/Resources"
APP="$ROOT/.build/NexGenVideo.app"
ZIP="$ROOT/.build/NexGenVideo.zip"
DMG="$ROOT/.build/NexGenVideo.dmg"
DSYM="$ROOT/.build/NexGenVideo.dSYM"

upload_dsyms() {
  if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
    echo "==> Sentry creds not set — skipping dSYM upload"
    return
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "!! sentry-cli not found in PATH — skipping dSYM upload"
    return
  fi
  echo "==> Uploading dSYM to Sentry"
  sentry-cli debug-files upload --include-sources "$DSYM" || echo "!! sentry-cli upload failed (continuing)"
}

package_release() {
  if [ -z "$NOTARY_KEY_FILE" ] || [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER" ]; then
    echo "!! notarization needs NOTARY_KEY_FILE / NOTARY_KEY_ID / NOTARY_ISSUER" >&2
    exit 1
  fi

  DMG_BG="$ROOT/assets/dmg-background.png"
  [ -f "$DMG_BG" ] || { echo "!! missing DMG background: $DMG_BG" >&2; exit 1; }
  [ -f "$RESOURCES/AppIcon.icns" ] || { echo "!! missing DMG volume icon" >&2; exit 1; }
  [ -f "$ROOT/scripts/dmg-settings.py" ] || { echo "!! missing dmg-settings.py" >&2; exit 1; }

  if [ -n "${DMGBUILD_BIN:-}" ]; then
    [ -x "$DMGBUILD_BIN" ] || { echo "!! DMGBUILD_BIN is not executable: $DMGBUILD_BIN" >&2; exit 1; }
  else
    DMG_VENV="$(mktemp -d)/dmgvenv"
    python3 -m venv "$DMG_VENV"
    "$DMG_VENV/bin/pip" install --quiet --disable-pip-version-check "dmgbuild==1.6.7"
    DMGBUILD_BIN="$DMG_VENV/bin/dmgbuild"
  fi

  echo "==> Zipping .app for notarization"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

  echo "==> Submitting to Apple notary (this can take several minutes)"
  "$ROOT/scripts/notarize.sh" "$ZIP"

  echo "==> Stapling ticket to .app"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"

  echo "==> Building DMG"
  rm -f "$DMG"
  DMG_VOLNAME="NexGenVideo"
  DMG_APP="$APP" DMG_BG="$DMG_BG" DMG_VOLICON="$RESOURCES/AppIcon.icns" \
    "$DMGBUILD_BIN" -s "$ROOT/scripts/dmg-settings.py" "$DMG_VOLNAME" "$DMG"

  echo "==> Codesigning DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"

  echo "==> Submitting DMG to notary"
  "$ROOT/scripts/notarize.sh" "$DMG"

  echo "==> Stapling DMG"
  xcrun stapler staple "$DMG"

  upload_dsyms

  echo ""
  echo "==> Done"
  echo "   App: $APP"
  echo "   DMG: $DMG"
  echo "   (Sparkle EdDSA signing + appcast update happen in the release workflow.)"
}

# For signed builds, resolve the Developer ID Application identity from the keychain.
if [ "$MODE" = "fast" ] || [ "$MODE" = "sign" ] || [ "$MODE" = "dist" ] || [ "$MODE" = "package" ]; then
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
  fi
  [ -n "$SIGN_IDENTITY" ] || { echo "!! no 'Developer ID Application' identity in the keychain (set SIGN_IDENTITY or import the cert)" >&2; exit 1; }
fi

if [ "$BPY_BUNDLE_MODE" != "full" ] && [ "$MODE" != "dev" ]; then
  echo "!! alternate bpy bundle modes are valid only for CI dev bundles" >&2
  exit 1
fi

if [ "$MODE" = "dist" ] || [ "$MODE" = "package" ]; then
  python3 "$ROOT/scripts/verify_bpy_runtime.py" --distribution
fi

if [ "$MODE" = "package" ]; then
  [ "$CONFIG" = "release" ] || { echo "!! --package requires release configuration" >&2; exit 1; }
  [ -d "$APP" ] || { echo "!! signed app not found at $APP — run release --sign first" >&2; exit 1; }
  codesign --verify --strict --verbose=2 "$APP"
  package_release
  exit 0
fi

echo "==> Building ($CONFIG)"
SWIFTPM_CACHE_ARGS=()
if [ -n "${NGV_SWIFTPM_CACHE_PATH:-}" ]; then
  SWIFTPM_CACHE_ARGS=(--cache-path "$NGV_SWIFTPM_CACHE_PATH")
fi
swift build "${SWIFTPM_CACHE_ARGS[@]}" -c "$CONFIG"
BIN_DIRECTORY="$(swift build "${SWIFTPM_CACHE_ARGS[@]}" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIRECTORY/NexGenVideo"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/XPCServices"
cp "$BIN_DIRECTORY/NexGenVideoDiagnostics" "$APP/Contents/Helpers/NexGenVideoDiagnostics"
cp "$BIN" "$APP/Contents/MacOS/NexGenVideo"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NGVSourceCommit string $(git rev-parse HEAD)" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NGVBuildConfiguration string $CONFIG" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NGVBuildSDK string $(xcrun --show-sdk-version)" "$APP/Contents/Info.plist"

if [ -n "$PLUGIN_CATALOG_URL" ]; then
  case "$PLUGIN_CATALOG_URL" in
    https://*) ;;
    *) echo "!! PLUGIN_CATALOG_URL must use https" >&2; exit 1 ;;
  esac
  echo "==> Embedding plugin catalog channel"
  /usr/libexec/PlistBuddy -c "Delete :NGVPluginCatalogURL" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NGVPluginCatalogURL string $PLUGIN_CATALOG_URL" "$APP/Contents/Info.plist"
fi

if [ -n "$SENTRY_DSN" ]; then
  echo "==> Injecting SentryDSN into Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :SentryDSN" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SentryDSN string $SENTRY_DSN" "$APP/Contents/Info.plist"
else
  echo "==> SENTRY_DSN not set — telemetry will be a no-op in this build"
fi

cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [ "$BPY_BUNDLE_MODE" = "full" ]; then
  BPY_RUNTIME_ROOT="${NGV_BPY_RUNTIME_ROOT:-$ROOT/.build/bpy-runtime}"
  "$ROOT/scripts/bundle_bpy_runtime.sh" \
    "$BPY_RUNTIME_ROOT" \
    "$BIN_DIRECTORY/NexGenVideoBpyService" \
    "$APP"
elif [ "$BPY_BUNDLE_MODE" = "boundary" ]; then
  [ "${CI:-}" = true ] || {
    echo "!! --bpy-boundary-probe-for-ci-transfer is restricted to CI test harnesses" >&2
    exit 1
  }
  "$ROOT/scripts/bundle_bpy_boundary_probe.sh" \
    "$BIN_DIRECTORY/NexGenVideoBpyService" \
    "$APP"
else
  [ "${CI:-}" = true ] || {
    echo "!! --without-bpy-runtime-for-ci-transfer is restricted to CI test harnesses" >&2
    exit 1
  }
  printf '%s\n' \
    'Managed bpy runtime intentionally omitted: non-product CI transfer while distribution is blocked.' \
    > "$APP/Contents/Resources/BPY_RUNTIME_OMITTED_FROM_NONPRODUCT_CI.txt"
fi

"$ROOT/scripts/stage_runtime_dependencies.sh" \
  "$APP/Contents/Frameworks" \
  "$APP/Contents/MacOS/NexGenVideo" \
  -- \
  "$BIN_DIRECTORY" \
  "$ROOT/Vendor" \
  "$ROOT/.build/artifacts"

# Stage source-controlled resources independently from compiler-generated resources.
RES_BUNDLE="$(dirname "$BIN")/NexGenVideo_NexGenVideo.bundle"
"$ROOT/scripts/compile_metal_resources.sh" "$ROOT/Metal" "$RES_BUNDLE"
"$ROOT/scripts/stage_app_resources.sh" "$RESOURCES" "$RES_BUNDLE" "$APP/Contents/Resources"

ENGINE_RES_BUNDLE="$BIN_DIRECTORY/NexGenEngine_NexGenEngine.bundle"
[ -d "$ENGINE_RES_BUNDLE" ] || {
  echo "!! missing NexGenEngine resource bundle: $ENGINE_RES_BUNDLE" >&2
  exit 1
}
engine_resource_roots=()
for candidate in \
    "$ENGINE_RES_BUNDLE" \
    "$ENGINE_RES_BUNDLE/Contents/Resources" \
    "$ENGINE_RES_BUNDLE/Resources"; do
  if [ -f "$candidate/ProductionKnowledge/manifest.json" ]; then
    engine_resource_roots+=("$candidate")
  fi
done
[ "${#engine_resource_roots[@]}" -eq 1 ] || {
  echo "!! expected exactly one ProductionKnowledge resource root in $ENGINE_RES_BUNDLE; found ${#engine_resource_roots[@]}" >&2
  exit 1
}
cp -R "$ENGINE_RES_BUNDLE" "$APP/Contents/Resources/NexGenEngine_NexGenEngine.bundle"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/NexGenVideo"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Codesigning fast app"
  "$ROOT/scripts/sign_app.sh" "$APP" fast "$BPY_BUNDLE_MODE" "$SIGN_IDENTITY"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/NexGenVideo" -o "$DSYM"
dsymutil "$BIN_DIRECTORY/NexGenVideoDiagnostics" -o "$ROOT/.build/NexGenVideoDiagnostics.dSYM"
dsymutil "$BIN_DIRECTORY/libNexGenEngine.dylib" -o "$ROOT/.build/NexGenEngine.dSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  "$ROOT/scripts/sign_app.sh" "$APP" dev "$BPY_BUNDLE_MODE" -
  upload_dsyms
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

"$ROOT/scripts/sign_app.sh" "$APP" distribution "$BPY_BUNDLE_MODE" "$SIGN_IDENTITY"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

package_release
