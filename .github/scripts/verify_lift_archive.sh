#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: $0 <archive.tar.gz>" >&2
  exit 2
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
expected_version="$(tr -d '[:space:]' < "$repo_root/apps/lift/VERSION")"
if [[ -z "$expected_version" ]]; then
  echo "apps/lift/VERSION must contain the Lift release version" >&2
  exit 1
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
LC_ALL=C tar -tzf "$1" > "$scratch/members"
# Ignore only the archive's root-directory entry. Reject duplicates and extras.
awk '{ path = $0; while (sub(/^\.\//, "", path)) {};
       sub(/\/$/, "", path); if (path != "") print path }' \
  "$scratch/members" > "$scratch/normalized"
printf 'lift-bench-stats\n' > "$scratch/expected"
if ! cmp -s "$scratch/expected" "$scratch/normalized"; then
  echo "Lift archive must contain exactly lift-bench-stats" >&2
  exit 1
fi
member="$(awk '$0 != "./" && $0 != "." { print }' "$scratch/members")"
mkdir "$scratch/payload"
tar -xzf "$1" -C "$scratch/payload" "$member"
payload="$scratch/payload/lift-bench-stats"
if [[ -L "$payload" || ! -f "$payload" || ! -x "$payload" ]] ||
   [[ -n "$(find "$payload" -type f -links +1 -print -quit)" ]]; then
  echo "Lift archive member must be a regular executable, not a link" >&2
  exit 1
fi
if ! version="$("$payload" --version)"; then
  echo "Lift archive executable failed its version probe" >&2
  exit 1
fi
if [[ "$version" != "$expected_version" ]]; then
  echo "Lift archive executable version does not match apps/lift/VERSION" >&2
  exit 1
fi
printf 'Lift archive verified: members=1 version=%s\n' "$expected_version"
