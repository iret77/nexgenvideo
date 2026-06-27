#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG

CONFIG="release"
MODE="dev"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
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
ENTITLEMENTS="$ROOT/scripts/PalmierPro.entitlements"
RESOURCES="$ROOT/Sources/PalmierPro/Resources"
APP="$ROOT/.build/NexGenVideo.app"
ZIP="$ROOT/.build/NexGenVideo.zip"
DMG="$ROOT/.build/NexGenVideo.dmg"

# For signed builds (fast/sign/dist), resolve the Developer ID Application identity from the keychain.
if [ "$MODE" = "fast" ] || [ "$MODE" = "sign" ] || [ "$MODE" = "dist" ]; then
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2; exit}')"
  fi
  [ -n "$SIGN_IDENTITY" ] || { echo "!! no 'Developer ID Application' identity in the keychain (set SIGN_IDENTITY or import the cert)" >&2; exit 1; }
fi

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PalmierPro"
SPARKLE_FW="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/PalmierPro"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

if [ -n "$SENTRY_DSN" ]; then
  echo "==> Injecting SentryDSN into Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :SentryDSN" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SentryDSN string $SENTRY_DSN" "$APP/Contents/Info.plist"
else
  echo "==> SENTRY_DSN not set — telemetry will be a no-op in this build"
fi

inject_plist() {
  local key="$1" value="$2"
  if [ -z "$value" ]; then
    echo "!! $key not set in $ENV_FILE — app will fatalError on launch" >&2
    return
  fi
  /usr/libexec/PlistBuddy -c "Delete :$key" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP/Contents/Info.plist"
}

echo "==> Injecting backend config into Info.plist"
inject_plist PalmierClerkPublishableKey "${CLERK_PUBLISHABLE_KEY:-}"
inject_plist PalmierConvexDeploymentURL "${CONVEX_DEPLOYMENT_URL:-}"
inject_plist PalmierConvexHttpURL "${CONVEX_HTTP_URL:-}"
cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/PalmierPro_PalmierPro.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -f "$RES_BUNDLE/palmier-pro.mcpb" ]; then
  cp "$RES_BUNDLE/palmier-pro.mcpb" "$APP/Contents/Resources/"
else
  echo "!! missing palmier-pro.mcpb in SwiftPM resource bundle at $RES_BUNDLE" >&2
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

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/PalmierPro"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Codesigning main app with $SIGN_IDENTITY (no timestamp, no helpers)"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM, no nested re-sign)"
  exit 0
fi

DSYM="$ROOT/.build/PalmierPro.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/PalmierPro" -o "$DSYM"

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

if [ -z "$NOTARY_KEY_FILE" ] || [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER" ]; then
  echo "!! notarization needs NOTARY_KEY_FILE / NOTARY_KEY_ID / NOTARY_ISSUER" >&2
  exit 1
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
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/NexGenVideo.app"
ln -s /Applications "$STAGING/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
hdiutil create \
  -volname "NexGen Video" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGING"

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
