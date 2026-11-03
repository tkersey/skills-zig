#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
classifier="$repo_root/.github/scripts/release_apps.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
git init -q
git config user.name release-test
git config user.email release-test@example.invalid
git -c commit.gpgsign=false commit -q --allow-empty -m base
base="$(git rev-parse HEAD)"
expected=$'seq\nlift\nledger\nmemory-note\nsiwc'

for path in \
  .github/scripts/release_artifacts.py \
  .github/scripts/test_release_artifacts.py \
  .github/scripts/test_release_artifact_ownership.sh
do
  mkdir -p "$(dirname "$path")"
  printf 'changed\n' > "$path"
  git add "$path"
  git -c commit.gpgsign=false commit -qm "change $path"
  head="$(git rev-parse HEAD)"
  for mode in affected ci-affected; do
    actual="$(bash "$classifier" "$mode" "$base" "$head")"
    if [[ "$actual" != "$expected" ]]; then
      printf '%s failed to select all consumers for %s\n' "$mode" "$path" >&2
      exit 1
    fi
  done
  base="$head"
done
printf 'Shared release helper ownership passed.\n'
