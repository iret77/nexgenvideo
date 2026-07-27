#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG
#   scripts/bundle.sh release --package         # notarize + DMG from an existing signed app

CONFIG="release"
MODE="dev"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    --package)     MODE="package" ;;
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
  # shellcheck disable=SC1091
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
ENTITLEMENTS="$ROOT/scripts/NexGenVideo.entitlements"
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
  xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait

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
  xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
    --wait

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

if [ "$MODE" = "package" ]; then
  [ "$CONFIG" = "release" ] || { echo "!! --package requires release configuration" >&2; exit 1; }
  [ -d "$APP" ] || { echo "!! signed app not found at $APP — run release --sign first" >&2; exit 1; }
  codesign --verify --strict --verbose=2 "$APP"
  package_release
  exit 0
fi

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NexGenVideo"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/NexGenVideo"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

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
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Vendored whisper.cpp (on-device ASR) — embed its framework so the app's AudioTranscribing seam
# resolves @rpath/whisper.framework/Versions/Current/whisper via the @executable_path/../Frameworks
# rpath added below. macOS/arm64 slice only (see Vendor/README.md).
WHISPER_FW="$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
if [ -d "$WHISPER_FW" ]; then
  cp -R "$WHISPER_FW" "$APP/Contents/Frameworks/whisper.framework"
else
  echo "!! missing vendored whisper.framework at $WHISPER_FW — the app links it and won't launch" >&2
  exit 1
fi

# ONNX Runtime (Demucs + Beat This! inference) — a downloaded pod-archive binaryTarget. Locate the
# macOS slice under SwiftPM's artifacts and embed it like the other frameworks.
ORT_FW="$(find "$ROOT/.build/artifacts" -type d -name onnxruntime.framework -path '*macos*' 2>/dev/null | head -1)"
if [ -n "$ORT_FW" ] && [ -d "$ORT_FW" ]; then
  cp -R "$ORT_FW" "$APP/Contents/Frameworks/onnxruntime.framework"
else
  echo "!! onnxruntime.framework not found under .build/artifacts — the app links it and won't launch" >&2
  exit 1
fi

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/NexGenVideo_NexGenVideo.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -f "$RES_BUNDLE/nexgen.mcpb" ]; then
  cp "$RES_BUNDLE/nexgen.mcpb" "$APP/Contents/Resources/"
else
  echo "!! missing nexgen.mcpb in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
if [ -d "$RES_BUNDLE/Changelog" ]; then
  cp -R "$RES_BUNDLE/Changelog" "$APP/Contents/Resources/"
else
  echo "!! missing Changelog/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if ! ls "$RES_BUNDLE"/*.metallib >/dev/null 2>&1; then
  echo "!! no .metallib in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi
cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"

# The production engine is a SHARED dynamic library (libNexGenEngine.dylib), linked by BOTH the app
# and every loadable format pack so they share one copy of the Pack/PackEntry metadata. Embed it in
# Frameworks; the main binary already carries the @executable_path/../Frameworks rpath (added below),
# and a plugin dylib's @rpath/libNexGenEngine.dylib dependency dyld-dedups onto this same image.
# Format packs themselves ship OUTSIDE the app (signed .ngvpack, fetched on demand) — nothing to copy.
ENGINE_DYLIB="$(dirname "$BIN")/libNexGenEngine.dylib"
if [ -f "$ENGINE_DYLIB" ]; then
  cp "$ENGINE_DYLIB" "$APP/Contents/Frameworks/libNexGenEngine.dylib"
else
  echo "!! missing libNexGenEngine.dylib at $ENGINE_DYLIB — the app links it dynamically and won't launch" >&2
  exit 1
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/NexGenVideo"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Codesigning main app with $SIGN_IDENTITY (no timestamp, no helpers)"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM, no nested re-sign)"
  exit 0
fi

echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/NexGenVideo" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  codesign --force --deep --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  upload_dsyms
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

echo "==> Codesigning nested Sparkle helpers"
SPARKLE_CURRENT="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
for helper in \
    "$SPARKLE_CURRENT/Autoupdate" \
    "$SPARKLE_CURRENT/Updater.app/Contents/MacOS/Updater" \
    "$SPARKLE_CURRENT/Updater.app" \
    "$SPARKLE_CURRENT/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$SPARKLE_CURRENT/XPCServices/Downloader.xpc" \
    "$SPARKLE_CURRENT/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$SPARKLE_CURRENT/XPCServices/Installer.xpc"; do
  [ -e "$helper" ] && codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$helper"
done

echo "==> Codesigning Sparkle framework"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Codesigning embedded engine dylib"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/Frameworks/libNexGenEngine.dylib"

echo "==> Codesigning embedded whisper framework"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/Frameworks/whisper.framework"

echo "==> Codesigning embedded onnxruntime framework"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/Frameworks/onnxruntime.framework"

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

package_release
