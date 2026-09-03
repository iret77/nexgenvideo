#!/usr/bin/env bash
set -euo pipefail

if [[ "${NGV_RELEASE_TOOL_COPY:-}" != "1" ]]; then
  SOURCE_TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    EXEC_TOOL_DIR="$RUNNER_TEMP/release-metadata-tool"
    mkdir -p "$EXEC_TOOL_DIR"
  else
    EXEC_TOOL_DIR="$(mktemp -d)"
  fi
  cp \
    "$SOURCE_TOOL_DIR/publish_release_metadata.sh" \
    "$SOURCE_TOOL_DIR/update_release_metadata.py" \
    "$SOURCE_TOOL_DIR/update_appcast.py" \
    "$EXEC_TOOL_DIR/"
  NGV_RELEASE_TOOL_COPY=1 exec "$EXEC_TOOL_DIR/publish_release_metadata.sh" "$@"
fi
TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ "$#" -ne 7 ]]; then
  echo "usage: publish_release_metadata.sh <version> <build> <dmg_length> <dmg_sha256> <ed_signature> <tag> <source_sha>" >&2
  exit 2
fi

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

VERSION="$1"
BUILD_NUMBER="$2"
DMG_LENGTH="$3"
DMG_SHA256="$4"
ED_SIGNATURE="$5"
TAG="$6"
SOURCE_SHA="$7"
BASE_BRANCH="${RELEASE_BASE_BRANCH:-main}"
CI_WORKFLOW="${RELEASE_CI_WORKFLOW:-ci.yml}"
METADATA_BRANCH="release/${TAG}-metadata"
INFO_PLIST="Sources/NexGenVideo/Resources/Info.plist"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "version must be X.Y.Z" >&2; exit 2; }
[[ "$TAG" == "v$VERSION" ]] \
  || { echo "tag must be v$VERSION" >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || { echo "build must be a positive integer" >&2; exit 2; }
[[ "$DMG_LENGTH" =~ ^[1-9][0-9]*$ ]] \
  || { echo "dmg_length must be a positive integer" >&2; exit 2; }
[[ "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  || { echo "dmg_sha256 must be a lowercase SHA-256 digest" >&2; exit 2; }
[[ -n "$ED_SIGNATURE" ]] \
  || { echo "ed_signature must not be empty" >&2; exit 2; }
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "source_sha must be a lowercase 40-character commit SHA" >&2; exit 2; }

release_json() {
  gh release view "$TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --json isDraft,assets
}

ensure_release_asset() {
  release_json | jq -e 'any(.assets[]; .name == "NexGenVideo.dmg")' >/dev/null \
    || { echo "::error::release $TAG has no NexGenVideo.dmg"; exit 1; }
  local verify_dir actual_length actual_sha
  verify_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ngv-release-dmg.XXXXXX")"
  gh release download "$TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --pattern NexGenVideo.dmg \
    --dir "$verify_dir"
  actual_length="$(stat -c%s "$verify_dir/NexGenVideo.dmg")"
  actual_sha="$(sha256sum "$verify_dir/NexGenVideo.dmg" | awk '{print $1}')"
  [[ "$actual_length" == "$DMG_LENGTH" ]] \
    || { echo "::error::release DMG length mismatch"; exit 1; }
  [[ "$actual_sha" == "$DMG_SHA256" ]] \
    || { echo "::error::release DMG checksum mismatch"; exit 1; }
}

metadata_is_current() {
  python3 "$TOOL_DIR/update_release_metadata.py" \
    "$VERSION" "$BUILD_NUMBER" "$DMG_LENGTH" "$ED_SIGNATURE" "$TAG" \
    --check >/dev/null 2>&1
}

verify_release_commit() {
  local sha="$1"
  local changed_paths parents
  parents="$(git show -s --format=%P "$sha")"
  [[ "$parents" == "$SOURCE_SHA" ]] \
    || { echo "::error::$sha is not the release-metadata child of $SOURCE_SHA"; exit 1; }
  changed_paths="$(git diff --no-renames --name-only "$SOURCE_SHA..$sha" | LC_ALL=C sort)"
  [[ "$changed_paths" == $'Sources/NexGenVideo/Resources/Info.plist\nappcast.xml' ]] \
    || { echo "::error::$sha contains changes beyond release metadata"; exit 1; }
  git checkout --detach "$sha"
  metadata_is_current \
    || { echo "::error::$sha does not contain the expected release metadata"; exit 1; }
}

find_release_commit() {
  local ref="$1"
  local candidate changed_paths
  RELEASE_COMMIT=""
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    changed_paths="$(git diff --no-renames --name-only "$SOURCE_SHA..$candidate" | LC_ALL=C sort)"
    if [[ "$changed_paths" != $'Sources/NexGenVideo/Resources/Info.plist\nappcast.xml' ]]; then
      continue
    fi
    git checkout --detach "$candidate"
    if metadata_is_current; then
      RELEASE_COMMIT="$candidate"
      break
    fi
  done < <(git rev-list --reverse "$SOURCE_SHA..$ref" -- "$INFO_PLIST" appcast.xml)
}

published_release_commit() {
  git fetch --no-tags origin "refs/tags/$TAG"
  git rev-parse "FETCH_HEAD^{commit}"
}

merge_gate_succeeded() {
  local sha="$1"
  gh api --method GET \
    -H "Accept: application/vnd.github+json" \
    "repos/$GITHUB_REPOSITORY/commits/$sha/check-runs?per_page=100" \
    -f check_name='Merge Gate' \
    -f filter=latest \
    --jq '([.check_runs[] | select(.app.slug == "github-actions")]
      | sort_by(.id) | last) as $check
      | ($check != null
         and $check.status == "completed"
         and $check.conclusion == "success")'
}

wait_for_merge_gate() {
  local sha="$1"
  if [[ "$(merge_gate_succeeded "$sha")" == "true" ]]; then
    return
  fi

  local previous_run_id
  previous_run_id="$(gh run list \
    --repo "$GITHUB_REPOSITORY" \
    --workflow "$CI_WORKFLOW" \
    --branch "$METADATA_BRANCH" \
    --event workflow_dispatch \
    --limit 100 \
    --json databaseId,headSha \
    --jq "[.[] | select(.headSha == \"$sha\") | .databaseId] | max // 0")"
  gh workflow run "$CI_WORKFLOW" \
    --repo "$GITHUB_REPOSITORY" \
    --ref "$METADATA_BRANCH"

  local run_id=""
  for _ in $(seq 1 150); do
    run_id="$(gh run list \
      --repo "$GITHUB_REPOSITORY" \
      --workflow "$CI_WORKFLOW" \
      --branch "$METADATA_BRANCH" \
      --event workflow_dispatch \
      --limit 100 \
      --json databaseId,headSha \
      --jq "[.[] | select(.headSha == \"$sha\" and .databaseId > $previous_run_id) | .databaseId] | max // empty")"
    [[ -n "$run_id" ]] && break
    sleep 2
  done
  [[ -n "$run_id" ]] \
    || { echo "::error::dispatched CI run was not registered"; exit 1; }
  timeout 1800 gh run watch "$run_id" \
    --repo "$GITHUB_REPOSITORY" \
    --exit-status \
    || { echo "::error::CI run $run_id failed or exceeded 30 minutes"; exit 1; }
  [[ "$(merge_gate_succeeded "$sha")" == "true" ]] \
    || { echo "::error::Merge Gate did not succeed for $sha"; exit 1; }
}

git fetch --no-tags origin "$BASE_BRANCH"
git checkout --detach "origin/$BASE_BRANCH"
ensure_release_asset
git fetch --no-tags origin "$SOURCE_SHA"
git cat-file -e "$SOURCE_SHA^{commit}"
git merge-base --is-ancestor "$SOURCE_SHA" "origin/$BASE_BRANCH" \
  || { echo "::error::release source $SOURCE_SHA is not on $BASE_BRANCH"; exit 1; }

if metadata_is_current; then
  main_sha="$(git rev-parse HEAD)"
  if [[ "$(release_json | jq -r .isDraft)" == "true" ]]; then
    find_release_commit "origin/$BASE_BRANCH"
    [[ -n "$RELEASE_COMMIT" ]] \
      || { echo "::error::could not recover the exact release metadata commit"; exit 1; }
    verify_release_commit "$RELEASE_COMMIT"
    gh release edit "$TAG" \
      --repo "$GITHUB_REPOSITORY" \
      --target "$RELEASE_COMMIT" \
      --draft=false
  else
    tag_sha="$(published_release_commit)"
    git merge-base --is-ancestor "$tag_sha" "$main_sha" \
      || { echo "::error::published $TAG does not belong to $BASE_BRANCH"; exit 1; }
    verify_release_commit "$tag_sha"
  fi
  echo "Release metadata already present on $BASE_BRANCH at $main_sha"
  exit 0
fi

remote_branch=false
if git fetch --no-tags origin "$METADATA_BRANCH"; then
  remote_branch=true
  git checkout -B "$METADATA_BRANCH" FETCH_HEAD
else
  git checkout -B "$METADATA_BRANCH" "$SOURCE_SHA"
fi
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

find_release_commit "$METADATA_BRANCH"
release_commit="$RELEASE_COMMIT"
git checkout "$METADATA_BRANCH"

if [[ -z "$release_commit" ]]; then
  [[ "$remote_branch" == "false" ]] \
    || { echo "::error::existing metadata branch has no valid release commit"; exit 1; }
  git merge-base --is-ancestor "$SOURCE_SHA" HEAD \
    || { echo "::error::metadata branch is not based on release source $SOURCE_SHA"; exit 1; }
  git checkout -B "$METADATA_BRANCH" "$SOURCE_SHA"
  python3 "$TOOL_DIR/update_release_metadata.py" \
    "$VERSION" "$BUILD_NUMBER" "$DMG_LENGTH" "$ED_SIGNATURE" "$TAG"
  git add "$INFO_PLIST" appcast.xml
  git commit -m "release: publish $TAG metadata (build $BUILD_NUMBER)"
  release_commit="$(git rev-parse HEAD)"
fi
verify_release_commit "$release_commit"
git checkout "$METADATA_BRANCH"

pr_number="$(gh pr list \
  --repo "$GITHUB_REPOSITORY" \
  --head "$METADATA_BRANCH" \
  --base "$BASE_BRANCH" \
  --state open \
  --limit 1 \
  --json number \
  --jq '.[0].number // empty')"

for attempt in 1 2; do
  git fetch --no-tags origin "$BASE_BRANCH"
  if ! git merge --no-edit "origin/$BASE_BRANCH"; then
    git merge --abort || true
    echo "::error::$BASE_BRANCH conflicts with release metadata for $TAG"
    exit 1
  fi
  python3 "$TOOL_DIR/update_release_metadata.py" \
    "$VERSION" "$BUILD_NUMBER" "$DMG_LENGTH" "$ED_SIGNATURE" "$TAG"
  git add "$INFO_PLIST" appcast.xml
  if ! git diff --cached --quiet; then
    git commit -m "release: publish $TAG metadata (build $BUILD_NUMBER)"
  fi
  git push --set-upstream origin "$METADATA_BRANCH"

  if [[ -z "$pr_number" ]]; then
    closed_pr="$(gh pr list \
      --repo "$GITHUB_REPOSITORY" \
      --head "$METADATA_BRANCH" \
      --base "$BASE_BRANCH" \
      --state closed \
      --limit 1 \
      --json number,mergedAt \
      --jq '.[0] | select(.mergedAt == null) | .number // empty')"
    [[ -z "$closed_pr" ]] \
      || { echo "::error::metadata PR #$closed_pr was closed without merging"; exit 1; }
    pr_url="$(gh pr create \
      --repo "$GITHUB_REPOSITORY" \
      --head "$METADATA_BRANCH" \
      --base "$BASE_BRANCH" \
      --title "Release $TAG metadata (build $BUILD_NUMBER)" \
      --body "Publishes the source build number and signed Sparkle appcast entry for $TAG. Created by the release workflow; merge is gated by the exact-head Merge Gate check.")"
    pr_number="${pr_url##*/}"
  fi

  head_sha="$(git rev-parse HEAD)"
  remote_head_sha="$(gh pr view "$pr_number" \
    --repo "$GITHUB_REPOSITORY" \
    --json headRefOid \
    --jq .headRefOid)"
  [[ "$remote_head_sha" == "$head_sha" ]] \
    || { echo "::error::metadata PR head changed unexpectedly"; exit 1; }
  wait_for_merge_gate "$head_sha"

  git fetch --no-tags origin "$BASE_BRANCH"
  if git merge-base --is-ancestor "origin/$BASE_BRANCH" "$head_sha"; then
    break
  fi
  [[ "$attempt" -lt 2 ]] \
    || { echo "::error::$BASE_BRANCH kept advancing while release metadata was validated"; exit 1; }
  echo "::notice::$BASE_BRANCH advanced; revalidating release metadata"
done

if [[ "$(release_json | jq -r .isDraft)" != "true" ]]; then
  tag_sha="$(published_release_commit)"
  [[ "$tag_sha" == "$release_commit" ]] \
    || { echo "::error::published $TAG points to $tag_sha, expected $release_commit"; exit 1; }
fi

gh pr merge "$pr_number" \
  --repo "$GITHUB_REPOSITORY" \
  --merge \
  --match-head-commit "$head_sha"

merged_at="$(gh pr view "$pr_number" \
  --repo "$GITHUB_REPOSITORY" \
  --json mergedAt \
  --jq .mergedAt)"
[[ "$merged_at" != "null" && -n "$merged_at" ]] \
  || { echo "::error::metadata PR #$pr_number did not merge"; exit 1; }

git fetch --no-tags origin "$BASE_BRANCH"
git merge-base --is-ancestor "$head_sha" "origin/$BASE_BRANCH" \
  || { echo "::error::$head_sha is not on $BASE_BRANCH after merge"; exit 1; }
git merge-base --is-ancestor "$release_commit" "origin/$BASE_BRANCH" \
  || { echo "::error::release commit is not on $BASE_BRANCH after merge"; exit 1; }
git checkout --detach "origin/$BASE_BRANCH"
metadata_is_current \
  || { echo "::error::release metadata is not current on $BASE_BRANCH"; exit 1; }
if [[ "$(release_json | jq -r .isDraft)" == "true" ]]; then
  gh release edit "$TAG" \
    --repo "$GITHUB_REPOSITORY" \
    --target "$release_commit" \
    --draft=false
else
  tag_sha="$(published_release_commit)"
  [[ "$tag_sha" == "$release_commit" ]] \
    || { echo "::error::published $TAG points to $tag_sha, expected $release_commit"; exit 1; }
fi
echo "Published $TAG metadata through PR #$pr_number at $head_sha"
