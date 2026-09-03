#!/bin/bash
set -euo pipefail

expected="$(printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort)"
actual="$(git diff --no-renames --name-only | LC_ALL=C sort)"

if [ "$actual" = "$expected" ]; then
  exit 0
fi

echo "::error::Tracked source changed unexpectedly"
echo "Expected tracked changes:"
if [ -n "$expected" ]; then
  printf '%s\n' "$expected"
else
  echo "(none)"
fi
echo "Actual tracked changes:"
if [ -n "$actual" ]; then
  printf '%s\n' "$actual"
else
  echo "(none)"
fi
git status --short --untracked-files=no
git diff --stat
if printf '%s\n' "$actual" | grep -qx 'Package.resolved'; then
  git diff -- Package.resolved
fi
exit 1
