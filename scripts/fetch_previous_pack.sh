#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 /path/to/current.ngvpack /path/to/output-directory" >&2
  exit 2
fi

current_pack="$1"
output_dir="$2"
[ -d "$current_pack" ] || { echo "missing current pack: $current_pack" >&2; exit 2; }
mkdir -p "$output_dir"

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

assets = []
page = 1
while True:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/releases?per_page=100&page={page}",
        headers=headers,
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        releases = json.load(response)
    for release in releases:
        assets.extend(release.get("assets", []))
    if len(releases) < 100:
        break
    page += 1

pattern = re.compile(rf"^{re.escape(pack_id)}-(\d+\.\d+\.\d+)\.ngvpack\.zip$")
prior_assets = []
for asset in assets:
    match = pattern.fullmatch(asset.get("name", ""))
    key = version(match.group(1)) if match else None
    digest = asset.get("digest") or ""
    if key is not None and key < current_key:
        checksum = digest[7:] if digest.startswith("sha256:") else None
        prior_assets.append((key, asset.get("created_at", ""), match.group(1), asset, checksum))
if not prior_assets:
    raise SystemExit(f"no previous release asset for {pack_id} before {current}")
_, _, previous, asset, digest = max(prior_assets, key=lambda item: (item[0], item[1]))
if digest is None:
    raise SystemExit(
        f"latest previous release asset lacks a GitHub SHA-256 digest: {asset.get('name')}"
    )
with open(output, "w") as handle:
    handle.write(f"{previous}\n{asset['browser_download_url']}\n{digest}\n")
PY

previous_version="$(sed -n '1p' "$selection")"
previous_url="$(sed -n '2p' "$selection")"
expected_sha="$(sed -n '3p' "$selection")"
archive="$output_dir/$pack_id-$previous_version.ngvpack.zip"
/usr/bin/curl -fsSL "$previous_url" -o "$archive"
actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[ "$actual_sha" = "$expected_sha" ] || {
  echo "previous pack checksum mismatch: expected $expected_sha, got $actual_sha" >&2
  exit 1
}

extract_dir="$output_dir/extracted"
mkdir -p "$extract_dir"
/usr/bin/ditto -x -k "$archive" "$extract_dir"
source_pack="$(find "$extract_dir" -maxdepth 1 -type d -name '*.ngvpack' -print -quit)"
[ -n "$source_pack" ] || { echo "previous pack archive contains no .ngvpack" >&2; exit 1; }
installed_pack="$output_dir/$previous_version.ngvpack"
/usr/bin/ditto "$source_pack" "$installed_pack"

actual_id="$(/usr/libexec/PlistBuddy -c 'Print :NGVPackID' "$installed_pack/Contents/Info.plist")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$installed_pack/Contents/Info.plist")"
[ "$actual_id" = "$pack_id" ] && [ "$actual_version" = "$previous_version" ] || {
  echo "previous pack metadata mismatch: $actual_id $actual_version" >&2
  exit 1
}

printf '%s\n' "$installed_pack"
