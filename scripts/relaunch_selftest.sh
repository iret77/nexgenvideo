#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/NexGenVideo.app" >&2
  exit 2
fi

app_path="$1"
binary="$app_path/Contents/MacOS/NexGenVideo"
[ -x "$binary" ] || { echo "missing executable: $binary" >&2; exit 2; }

state_dir="$(mktemp -d)"
state_file="$state_dir/state"
log_file="$state_dir/relaunch.log"
first_pid=""

cleanup() {
  if [ -n "$first_pid" ] && kill -0 "$first_pid" 2>/dev/null; then
    kill "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
  fi
  rm -rf "$state_dir"
}
trap cleanup EXIT

NGV_SELFTEST_RELAUNCH="$state_file" "$binary" >"$log_file" 2>&1 &
first_pid=$!

attempts=0
while [ "$attempts" -lt 300 ]; do
  state="$(cat "$state_file" 2>/dev/null || true)"
  if [ "$state" = "reopened" ]; then
    if ! wait "$first_pid"; then
      cat "$log_file" >&2
      echo "initial app process did not terminate cleanly" >&2
      exit 1
    fi
    cat "$log_file"
    echo "OK: clean Home restart exited and reopened the exact app bundle"
    exit 0
  fi
  case "$state" in
    failed:*)
      cat "$log_file" >&2
      echo "relaunch self-test failed: ${state#failed: }" >&2
      exit 1
      ;;
  esac
  if ! kill -0 "$first_pid" 2>/dev/null && [ "$state" != "armed" ]; then
    cat "$log_file" >&2
    echo "relaunch self-test exited before arming (state=$state)" >&2
    exit 1
  fi
  attempts=$((attempts + 1))
  /bin/sleep 0.1
done

cat "$log_file" >&2
echo "relaunch self-test timed out (state=$(cat "$state_file" 2>/dev/null || true))" >&2
exit 1
