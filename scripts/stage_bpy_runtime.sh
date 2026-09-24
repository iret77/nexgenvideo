#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/Runtime/bpy/runtime-lock.json"
DESTINATION="${1:?bpy runtime destination required}"

python3 "$ROOT/scripts/verify_bpy_runtime.py"
case "$DESTINATION" in
  /|"$ROOT"|"$ROOT"/) echo "refusing broad bpy runtime destination: $DESTINATION" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fetch() {
  local url="$1" expected="$2" output="$3" expected_size="${4:-}"
  curl --fail --location --retry 3 --output "$output" "$url"
  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || {
    echo "checksum mismatch for $(basename "$output"): $actual" >&2
    exit 1
  }
  if [ -n "$expected_size" ] && [ "$(stat -f %z "$output")" != "$expected_size" ]; then
    echo "size mismatch for $(basename "$output")" >&2
    exit 1
  fi
}

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/python" "$DESTINATION/site-packages" \
  "$DESTINATION/licenses/wheels" "$DESTINATION/licenses/python"

runtime_url="$(jq -r .runtime.artifact.url "$LOCK")"
runtime_sha="$(jq -r .runtime.artifact.sha256 "$LOCK")"
runtime_archive="$WORK/python.tar.zst"
fetch "$runtime_url" "$runtime_sha" "$runtime_archive"
mkdir -p "$WORK/python-full"
tar -xf "$runtime_archive" -C "$WORK/python-full" \
  python/install python/PYTHON.json python/licenses
cp -R "$WORK/python-full/python/install/." "$DESTINATION/python/"
cp "$WORK/python-full/python/PYTHON.json" "$DESTINATION/PYTHON.json"
cp -R "$WORK/python-full/python/licenses/." "$DESTINATION/licenses/python/"

while IFS=$'\t' read -r name filename url sha; do
  wheel="$WORK/$filename"
  fetch "$url" "$sha" "$wheel"
  wheel_root="$WORK/wheel-$name"
  mkdir -p "$wheel_root"
  ditto -x -k "$wheel" "$wheel_root"
  data_roots=("$wheel_root"/*.data)
  if [ -d "${data_roots[0]}" ]; then
    for data_root in "${data_roots[@]}"; do
      for scheme in purelib platlib; do
        if [ -d "$data_root/$scheme" ]; then
          cp -R "$data_root/$scheme/." "$DESTINATION/site-packages/"
        fi
      done
      find "$data_root" -mindepth 1 -maxdepth 1 \
        ! -name purelib ! -name platlib -print -quit | grep -q . && {
          echo "unsupported wheel data scheme in $filename" >&2
          exit 1
        }
      rm -rf "$data_root"
    done
  fi
  dist_info="$(find "$wheel_root" -maxdepth 1 -type d -name '*.dist-info' -print -quit)"
  [ -n "$dist_info" ] || { echo "missing dist-info in $filename" >&2; exit 1; }
  mkdir -p "$DESTINATION/licenses/wheels/$name"
  find "$dist_info" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) \
    -exec cp {} "$DESTINATION/licenses/wheels/$name/" \;
  if [ -d "$dist_info/licenses" ]; then
    cp -R "$dist_info/licenses/." "$DESTINATION/licenses/wheels/$name/"
  fi
  cp -R "$wheel_root/." "$DESTINATION/site-packages/"
done < <(jq -r '.wheels[] | [.name,.filename,.url,.sha256] | @tsv' "$LOCK")

python3 - "$LOCK" "$DESTINATION/site-packages" <<'PY'
import base64
import csv
import hashlib
import json
import pathlib
import sys

lock_path, site_path = map(pathlib.Path, sys.argv[1:])
lock = json.loads(lock_path.read_text())
layout = lock["bpyWheelLayout"]
record_path = site_path / layout["recordPath"]
with record_path.open(newline="") as handle:
    records = {row[0]: row[1:] for row in csv.reader(handle)}
declared = set(layout["nativeLibraries"])
discovered = {
    path.relative_to(site_path).as_posix()
    for path in (site_path / "bpy/lib").glob("*.dylib")
}
if discovered != declared:
    raise SystemExit(f"bpy native-library inventory drift: {sorted(discovered ^ declared)}")
for relative in [layout["entryPoint"], *layout["nativeLibraries"]]:
    fields = records.get(relative)
    path = site_path / relative
    if not fields or len(fields) != 2 or not fields[0].startswith("sha256=") or not fields[1]:
        raise SystemExit(f"missing hashed RECORD entry: {relative}")
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(chunk)
    digest = base64.urlsafe_b64encode(checksum.digest()).decode().rstrip("=")
    if fields[0] != f"sha256={digest}" or int(fields[1]) != path.stat().st_size:
        raise SystemExit(f"RECORD mismatch: {relative}")
PY

find "$DESTINATION/python" -type d \( -name pip -o -name 'pip-*.dist-info' -o -name ensurepip \) \
  -prune -exec rm -rf {} +
rm -f "$DESTINATION/python/bin/pip" \
  "$DESTINATION/python/bin/pip3" \
  "$DESTINATION/python/bin/pip3.13"
cp "$LOCK" "$DESTINATION/runtime-lock.json"
cp "$ROOT/Runtime/bpy/NOTICE.md" "$DESTINATION/NOTICE.md"
if [ "$(jq -r .distributionStatus "$LOCK")" = ready ]; then
  mkdir -p "$DESTINATION/corresponding-source" "$DESTINATION/licenses/distribution"
  while IFS=$'\t' read -r filename url sha size; do
    fetch "$url" "$sha" "$DESTINATION/corresponding-source/$filename" "$size"
  done < <(jq -r '.distributionClosure.sourceArchives[] | [.filename,.url,.sha256,.size] | @tsv' "$LOCK")
  while IFS= read -r relative; do
    cp "$ROOT/$relative" "$DESTINATION/licenses/distribution/$(basename "$relative")"
  done < <(jq -r '[.distributionClosure.wheelBinaryProvenance.path] + [.distributionClosure.noticeFiles[].path] | .[]' "$LOCK")
fi
printf '%s\n' "$(shasum -a 256 "$LOCK" | awk '{print $1}')" > "$DESTINATION/.complete"

test -x "$DESTINATION/python/bin/python3"
BPY_ENTRYPOINT="$(jq -r .bpyWheelLayout.entryPoint "$LOCK")"
test -f "$DESTINATION/site-packages/$BPY_ENTRYPOINT"
test ! -e "$DESTINATION/python/bin/pip"
test ! -e "$DESTINATION/python/bin/pip3"
test ! -e "$DESTINATION/python/bin/pip3.13"
echo "staged managed bpy runtime at $DESTINATION"
