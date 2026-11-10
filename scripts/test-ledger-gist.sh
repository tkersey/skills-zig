#!/usr/bin/env bash
set -euo pipefail

binary=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
work=$(mktemp -d "${TMPDIR:-/tmp}/ledger-gist.XXXXXX")
trap 'test -n "${work:-}" && rm -rf -- "$work"' EXIT
export LEDGER_CACHE_DIR="$work/cache"
mkdir "$work/cwd"
cd "$work/cwd"

capabilities=$("$binary" capabilities --format json)
jq -e '.schema == "ledger-capabilities/v1" and
  (.transports | index("github-gist/v1")) != null and
  (.result_schemas | index("ledger-gist/v1")) != null and
  (.result_schemas | index("ledger-gist-error/v1")) != null' \
  <<<"$capabilities" >/dev/null

gist_help=$("$binary" gist --help)
grep -Fq 'ledger gist create' <<<"$gist_help"
grep -Fq 'ledger gist read' <<<"$gist_help"
grep -Fq 'LEDGER_GITHUB_TOKEN' <<<"$gist_help"
test "$("$binary" gist create --help)" = "$gist_help"
test "$("$binary" gist read --help)" = "$gist_help"

if bad_ref=$("$binary" gist read --gist https://example.com/abcde --format json); then
  exit 1
fi
jq -e '.schema == "ledger-gist-error/v1" and .error == "InvalidGistUrl" and
  .attempted_create == false and .gist_id == null and .revision == null and
  .authority_granted == false and (has("storage_mutated") | not)' \
  <<<"$bad_ref" >/dev/null

if no_token=$(env -u LEDGER_GITHUB_TOKEN -u GH_TOKEN -u GITHUB_TOKEN \
  SEQ_GITHUB_TOKEN=unused-legacy-token \
  "$binary" gist create --input "$work/missing.json" --format json); then
  exit 1
fi
jq -e '.schema == "ledger-gist-error/v1" and .error == "GistTokenRequired" and
  .attempted_create == false and .gist_id == null and .revision == null and
  .authority_granted == false and (has("storage_mutated") | not)' \
  <<<"$no_token" >/dev/null

if missing_id=$("$binary" gist read --format json); then
  exit 1
fi
jq -e '.schema == "ledger-gist-error/v1" and .error == "MissingGistId" and
  .attempted_create == false' <<<"$missing_id" >/dev/null

test ! -e "$work/cache"
shopt -s nullglob dotglob
entries=("$work/cwd"/*)
test "${#entries[@]}" -eq 0

printf '%s\n' 'Ledger gist smoke tests passed'
