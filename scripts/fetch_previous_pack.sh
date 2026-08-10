#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 /path/to/current.ngvpack /path/to/output-directory [sign-identity]" >&2
  exit 2
fi

current_pack="$1"
output_dir="$2"
sign_identity="${3:-}"
[ -d "$current_pack" ] || { echo "missing current pack: $current_pack" >&2; exit 2; }
mkdir -p "$output_dir/compatible" "$output_dir/incompatible"

pack_id="$(/usr/libexec/PlistBuddy -c 'Print :NGVPackID' "$current_pack/Contents/Info.plist")"
current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$current_pack/Contents/Info.plist")"
selection="$output_dir/selection.txt"
repository="${GITHUB_REPOSITORY:-iret77/nexgenvideo}"

python3 - "$repository" "$pack_id" "$current_version" "$selection" <<'PY'
import json, os, re, sys, urllib.request

repository, pack_id, current, output = sys.argv[1:]

def version(value):
    parts = value.split(".")
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        return None
    return tuple(int(part) for part in parts)

current_key = version(current)
if current_key is None:
    raise SystemExit(f"invalid current pack version: {current}")
token = os.environ.get("GH_TOKEN")
headers = {"Accept": "application/vnd.github+json", "User-Agent": "NexGenVideo-CI"}
if token:
    headers["Authorization"] = f"Bearer {token}"

request = urllib.request.Request(
    f"https://api.github.com/repos/{repository}/releases/tags/plugins",
    headers=headers,
)
with urllib.request.urlopen(request, timeout=30) as response:
    assets = json.load(response).get("assets", [])

pattern = re.compile(rf"^{re.escape(pack_id)}-(\d+\.\d+\.\d+)\.ngvpack\.zip$")
prior_assets = {}
for asset in assets:
    match = pattern.fullmatch(asset.get("name", ""))
    key = version(match.group(1)) if match else None
    digest = asset.get("digest") or ""
    if key is not None and key < current_key:
        checksum = digest[7:] if digest.startswith("sha256:") else None
        candidate = (asset.get("created_at", ""), match.group(1), asset, checksum)
        if key not in prior_assets or candidate[0] > prior_assets[key][0]:
            prior_assets[key] = candidate
if not prior_assets:
    raise SystemExit(f"no previous release asset for {pack_id} before {current}")
with open(output, "w") as handle:
    for key in sorted(prior_assets):
        _, previous, asset, digest = prior_assets[key]
        if digest is None:
            raise SystemExit(
                f"previous release asset lacks a GitHub SHA-256 digest: {asset.get('name')}"
            )
        handle.write(f"{previous}\t{asset['browser_download_url']}\t{digest}\n")
PY

contract_source="$(cd "$(dirname "$0")/.." && pwd)/Engine/Sources/NexGenEngine/Packs/EngineContract.swift"
minimum_contract="$(grep -Eo '^[[:space:]]*public static let minimumCompatible = [0-9]+[[:space:]]*$' \
  "$contract_source" | grep -Eo '[0-9]+' | head -1 || true)"
current_contract="$(/usr/libexec/PlistBuddy -c 'Print :NGVEngineContract' \
  "$current_pack/Contents/Info.plist" 2>/dev/null)" || current_contract=""
for contract in "$minimum_contract" "$current_contract"; do
  case "$contract" in
    ''|*[!0-9]*)
      echo "invalid engine contracts: minimum=$minimum_contract current=$current_contract" >&2
      exit 1
      ;;
  esac
done

latest_compatible=""
latest_historical_version=""
tab="$(printf '\t')"
while IFS="$tab" read -r previous_version previous_url expected_sha; do
  [ -n "$previous_version" ] || continue
  latest_historical_version="$previous_version"
  archive="$output_dir/$pack_id-$previous_version.ngvpack.zip"
  /usr/bin/curl -fsSL "$previous_url" -o "$archive"
  actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [ "$actual_sha" = "$expected_sha" ] || {
    echo "previous pack checksum mismatch: expected $expected_sha, got $actual_sha" >&2
    exit 1
  }

  extract_dir="$output_dir/extracted-$previous_version"
  mkdir -p "$extract_dir"
  /usr/bin/ditto -x -k "$archive" "$extract_dir"
  source_pack="$(find "$extract_dir" -maxdepth 1 -type d -name '*.ngvpack' -print -quit)"
  [ -n "$source_pack" ] || { echo "previous pack archive contains no .ngvpack" >&2; exit 1; }
  actual_id="$(/usr/libexec/PlistBuddy -c 'Print :NGVPackID' "$source_pack/Contents/Info.plist")"
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$source_pack/Contents/Info.plist")"
  [ "$actual_id" = "$pack_id" ] && [ "$actual_version" = "$previous_version" ] || {
    echo "previous pack metadata mismatch: $actual_id $actual_version" >&2
    exit 1
  }
  previous_contract="$(/usr/libexec/PlistBuddy -c 'Print :NGVEngineContract' \
    "$source_pack/Contents/Info.plist" 2>/dev/null)" || previous_contract="0"
  case "$previous_contract" in
    ''|*[!0-9]*)
      echo "invalid previous engine contract: $previous_contract" >&2
      exit 1
      ;;
  esac

  if [ "$previous_contract" -ge "$minimum_contract" ] \
    && [ "$previous_contract" -le "$current_contract" ]; then
    installed_pack="$output_dir/compatible/$previous_version.ngvpack"
    latest_compatible="$installed_pack"
  else
    installed_pack="$output_dir/incompatible/$previous_version.ngvpack"
  fi
  /usr/bin/ditto --noqtn "$source_pack" "$installed_pack"
done < "$selection"

[ -n "$latest_historical_version" ] || {
  echo "no previous pack was selected for $pack_id" >&2
  exit 1
}

if [ -n "$latest_compatible" ]; then
  lifecycle_pack="$latest_compatible"
else
  lifecycle_pack="$output_dir/lifecycle-$latest_historical_version.ngvpack"
  /usr/bin/ditto --noqtn "$current_pack" "$lifecycle_pack"
  /usr/libexec/PlistBuddy -c \
    "Set :CFBundleShortVersionString $latest_historical_version" \
    "$lifecycle_pack/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $latest_historical_version" \
    "$lifecycle_pack/Contents/Info.plist"
  lifecycle_binary="$lifecycle_pack/Contents/MacOS/$pack_id"
  if [ -n "$sign_identity" ]; then
    /usr/bin/codesign --force --options runtime --timestamp \
      --sign "$sign_identity" "$lifecycle_binary"
    /usr/bin/codesign --force --options runtime --timestamp \
      --sign "$sign_identity" "$lifecycle_pack"
  else
    /usr/bin/codesign --force --sign - "$lifecycle_binary"
    /usr/bin/codesign --force --sign - "$lifecycle_pack"
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "$lifecycle_pack"
fi

printf '%s\n' "$lifecycle_pack"
