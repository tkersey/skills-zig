#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
auto_release="${1:-$repo_root/.github/workflows/auto-release.yml}"
seq_release="${2:-$repo_root/.github/workflows/release-seq.yml}"

for workflow in "$auto_release" "$seq_release"; do
  if [[ ! -r "$workflow" ]]; then
    echo "Release workflow is not readable: $workflow" >&2
    exit 1
  fi
done

expect_count() {
  local workflow="$1"
  local expected="$2"
  local needle="$3"
  local observed

  observed="$(
    awk -v needle="$needle" '
      {
        line = $0
        while ((offset = index(line, needle)) != 0) {
          count += 1
          line = substr(line, offset + length(needle))
        }
      }
      END {
        print count + 0
      }
    ' "$workflow"
  )"

  if [[ "$observed" != "$expected" ]]; then
    echo "$(basename "$workflow") expected $expected occurrence(s) of '$needle'; found $observed" >&2
    exit 1
  fi
}

expect_count "$auto_release" 1 "matrix.app != 'seq'"
expect_count "$auto_release" 1 'Seq tag creation is deferred until qualification succeeds.'
expect_count "$auto_release" 1 '--ref "${GITHUB_REF_NAME}"'
expect_count "$auto_release" 1 '-f "commit_sha=${GITHUB_SHA}"'

expect_count "$seq_release" 1 "commit_sha:"
expect_count "$seq_release" 1 "REQUESTED_COMMIT:"
expect_count "$seq_release" 2 'ref: ${{ env.RELEASE_COMMIT }}'
expect_count "$seq_release" 1 '[[ ! "${RELEASE_COMMIT}" =~ ^[0-9a-f]{40}$ ]]'
expect_count "$seq_release" 1 '"${GITHUB_REF_TYPE}" != "tag"'
expect_count "$seq_release" 1 '"${checkout_sha}" != "${RELEASE_COMMIT}"'
expect_count "$seq_release" 1 "needs: release"
expect_count "$seq_release" 1 "Create or verify qualified Seq release tag"
expect_count "$seq_release" 1 '-f "sha=${RELEASE_COMMIT}"'
expect_count "$seq_release" 1 '"${tag_sha}" != "${RELEASE_COMMIT}"'
expect_count "$seq_release" 1 'runs_on: windows-2025'
expect_count "$seq_release" 1 'release_artifacts.py windows seq --tag "$RELEASE_TAG"'
expect_count "$seq_release" 2 'release_artifacts.py verify-set seq "$RELEASE_TAG" release-assets'

publish_line="$(grep -n '^  publish:$' "$seq_release" | cut -d: -f1)"
verify_line="$(grep -n 'name: Verify seq artifact set' "$seq_release" | cut -d: -f1)"
tag_line="$(grep -n 'name: Create or verify qualified Seq release tag' "$seq_release" | cut -d: -f1)"
if [[ -z "$publish_line" || -z "$verify_line" || -z "$tag_line" ||
      "$verify_line" -le "$publish_line" || "$tag_line" -le "$verify_line" ]]; then
  echo "Seq tag authority must follow exact archive admission inside the post-qualification publish job." >&2
  exit 1
fi

echo "Seq qualify-before-tag release transaction is valid."
