#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 /path/to/NexGenVideo.app /path/to/old.ngvpack /path/to/new.ngvpack" >&2
  exit 2
fi

[ -d "$1" ] || { echo "missing app: $1" >&2; exit 2; }
[ -d "$2" ] || { echo "missing old pack: $2" >&2; exit 2; }
[ -d "$3" ] || { echo "missing new pack: $3" >&2; exit 2; }
app_path="$(cd "$1" && pwd -P)"
old_pack="$(cd "$2" && pwd -P)"
new_pack="$(cd "$3" && pwd -P)"
binary="$app_path/Contents/MacOS/NexGenVideo"
[ -x "$binary" ] || { echo "missing executable: $binary" >&2; exit 2; }

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

pack_id="$(plist_value "$old_pack" NGVPackID)"
old_version="$(plist_value "$old_pack" CFBundleShortVersionString)"
new_id="$(plist_value "$new_pack" NGVPackID)"
new_version="$(plist_value "$new_pack" CFBundleShortVersionString)"
[ "$pack_id" = "$new_id" ] || { echo "pack ids differ: $pack_id / $new_id" >&2; exit 2; }
[ "$old_version" != "$new_version" ] || { echo "pack versions must differ" >&2; exit 2; }

state_dir="$(mktemp -d)"
state_file="$state_dir/state"
marker_file="$state_dir/started"
defaults_backup="$state_dir/defaults.plist"
pack_root="$HOME/Library/Application Support/NexGenVideo/Plugins/$pack_id"
pack_backup="$state_dir/pack-backup"
diagnostics="$HOME/Library/Logs/NexGenVideo"
test_pid=""
had_defaults=0
had_pack_root=0
test_pack_root_installed=0
touch "$marker_file"

if pgrep -x NexGenVideo >/dev/null 2>&1; then
  echo "a NexGenVideo process is already running; refusing to disturb it" >&2
  exit 2
fi

cleanup() {
  status=$?
  trap - EXIT
  set +e
  state="$(cat "$state_file" 2>/dev/null || true)"
  case "$state" in
    launched\ *|pressing\ *|reopened\ *) test_pid="${state##* }" ;;
  esac
  if [ -n "$test_pid" ] && kill -0 "$test_pid" 2>/dev/null; then
    command_line="$(ps -ww -p "$test_pid" -o command= 2>/dev/null || true)"
    case "$command_line" in
      "$binary"|"$binary "*) kill "$test_pid" 2>/dev/null || true ;;
    esac
  fi
  if [ "$test_pack_root_installed" -eq 1 ]; then
    rm -rf "$pack_root"
  fi
  if [ "$had_pack_root" -eq 1 ] && [ -e "$pack_backup" ]; then
    mv "$pack_backup" "$pack_root" || status=1
  fi
  if [ "$had_defaults" -eq 1 ]; then
    defaults delete de.h5ventures.nexgenvideo >/dev/null 2>&1 || true
    defaults import de.h5ventures.nexgenvideo "$defaults_backup" >/dev/null || status=1
  else
    defaults delete de.h5ventures.nexgenvideo >/dev/null 2>&1 || true
  fi
  rm -rf "$state_dir"
  exit "$status"
}
trap cleanup EXIT

if defaults export de.h5ventures.nexgenvideo "$defaults_backup" >/dev/null 2>&1; then
  had_defaults=1
elif defaults read de.h5ventures.nexgenvideo >/dev/null 2>&1; then
  echo "could not back up existing NexGenVideo defaults" >&2
  exit 1
fi
if [ -e "$pack_root" ]; then
  had_pack_root=1
  mv "$pack_root" "$pack_backup"
fi

mkdir -p "$pack_root"
test_pack_root_installed=1
/usr/bin/ditto "$old_pack" "$pack_root/$old_version.ngvpack"
/usr/bin/ditto "$new_pack" "$pack_root/$new_version.ngvpack"
defaults write de.h5ventures.nexgenvideo NGVSelectedPackVersions -dict "$pack_id" "$old_version"
app_version="$(plist_value "$app_path" CFBundleShortVersionString)"
defaults write de.h5ventures.nexgenvideo lastSeenVersion "$app_version"

/usr/bin/open -n "$app_path" --args \
  --ngv-relaunch-selftest-start \
  "$state_file" \
  "$app_path" \
  "$pack_id" \
  "$old_version" \
  "$new_version"

attempts=0
while [ "$attempts" -lt 900 ]; do
  state="$(cat "$state_file" 2>/dev/null || true)"
  case "$state" in
    reopened\ *)
      fresh_hang="$(find "$diagnostics" -type f -newer "$marker_file" \
        \( -name '*main-thread-hang.json' -o -name '*main-thread-hang.sample.txt' \) \
        -print -quit 2>/dev/null || true)"
      [ -z "$fresh_hang" ] || {
        echo "relaunch self-test produced a main-thread hang report: $fresh_hang" >&2
        exit 1
      }
      echo "OK: the real Home button activated $pack_id $new_version and Home remained interactive"
      exit 0
      ;;
    failed:*)
      echo "relaunch self-test failed: ${state#failed: }" >&2
      exit 1
      ;;
  esac
  attempts=$((attempts + 1))
  /bin/sleep 0.1
done

echo "relaunch self-test timed out (state=$(cat "$state_file" 2>/dev/null || true))" >&2
exit 1
