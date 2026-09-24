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
  local url="$1" expected="$2" output="$3"
  curl --fail --location --retry 3 --output "$output" "$url"
  local actual
  actual="$(shasum -a 256 "$output" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || {
    echo "checksum mismatch for $(basename "$output"): $actual" >&2
    exit 1
  }
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

find "$DESTINATION/python" -type d \( -name pip -o -name 'pip-*.dist-info' -o -name ensurepip \) \
  -prune -exec rm -rf {} +
rm -f "$DESTINATION/python/bin/pip" \
  "$DESTINATION/python/bin/pip3" \
  "$DESTINATION/python/bin/pip3.13"
cp "$LOCK" "$DESTINATION/runtime-lock.json"
cp "$ROOT/Runtime/bpy/NOTICE.md" "$DESTINATION/NOTICE.md"
printf '%s\n' "$(shasum -a 256 "$LOCK" | awk '{print $1}')" > "$DESTINATION/.complete"

test -x "$DESTINATION/python/bin/python3"
test -f "$DESTINATION/site-packages/bpy/__init__.py"
test ! -e "$DESTINATION/python/bin/pip"
test ! -e "$DESTINATION/python/bin/pip3"
test ! -e "$DESTINATION/python/bin/pip3.13"
echo "staged managed bpy runtime at $DESTINATION"
