#!/bin/bash
set -euo pipefail
case "${1:-}" in
import)
set -euo pipefail
KEYCHAIN="$RUNNER_TEMP/signing.keychain-db"
KEYCHAIN_PW="$(openssl rand -base64 24)"
CERT_PATH="$RUNNER_TEMP/cert.p12"
printf '%s' "$CERT_B64" | base64 --decode > "$CERT_PATH"
security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security import "$CERT_PATH" -P "$CERT_PW" -A -t cert -f pkcs12 \
  -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" \
  $(security list-keychains -d user | sed 's/"//g')
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | awk '/Developer ID Application/{print $2; exit}')"
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' identity in the .p12"; exit 1; }
echo "SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "SIGN_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
rm -f "$CERT_PATH"
;;
keys)
set -euo pipefail
printf '%s' "$NOTARY_KEY_B64" | base64 --decode > "$RUNNER_TEMP/notary.p8"
{
  echo "NOTARY_KEY_FILE=$RUNNER_TEMP/notary.p8"
  echo "NOTARY_KEY_ID=$NOTARY_KEY_ID"
  echo "NOTARY_ISSUER=$NOTARY_ISSUER"
} >> "$GITHUB_ENV"
if [ -n "${SPARKLE_PRIV_B64:-}" ]; then
  printf '%s' "$SPARKLE_PRIV_B64" | base64 --decode > "$RUNNER_TEMP/sparkle_priv.der"
  echo "SPARKLE_PRIV_DER=$RUNNER_TEMP/sparkle_priv.der" >> "$GITHUB_ENV"
elif [ "$REL_DRY" = "false" ]; then
  echo "::error::SPARKLE_ED_PRIVATE_KEY is required for a published release"
  exit 1
fi
;;
validate)
set -euo pipefail
xcrun notarytool history \
  --key "$NOTARY_KEY_FILE" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER" >/dev/null
DMG_VENV="$RUNNER_TEMP/dmgvenv"
python3 -m venv "$DMG_VENV"
"$DMG_VENV/bin/pip" install \
  --quiet \
  --disable-pip-version-check \
  "dmgbuild==1.6.7" \
  "cryptography==50.0.2"
[ -x "$DMG_VENV/bin/dmgbuild" ]
if [ -n "${SPARKLE_PRIV_DER:-}" ]; then
  "$DMG_VENV/bin/python" scripts/sparkle_ed25519.py check "$SPARKLE_PRIV_DER"
fi
echo "DMGBUILD_BIN=$DMG_VENV/bin/dmgbuild" >> "$GITHUB_ENV"
echo "DMG_PYTHON=$DMG_VENV/bin/python" >> "$GITHUB_ENV"
;;
*) echo "Unknown release credential operation" >&2; exit 2 ;;
esac
