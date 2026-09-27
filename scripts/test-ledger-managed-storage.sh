#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
bin=${1:-"$root_dir/zig-out/bin/ledger"}
bin=$(cd "$(dirname "$bin")" && printf '%s/%s' "$(pwd -P)" "$(basename "$bin")")
definition="$root_dir/apps/ledger/src/v1/fixtures/plain-event-definition.json"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
trap 'status=$?; printf "managed custody failure at line %s (exit %s)\n" "$LINENO" "$status" >&2; for result in "$tmp"/*.json; do test ! -f "$result" || { printf "%s\n" "$result" >&2; cat "$result" >&2; }; done; exit "$status"' ERR
store="$tmp/durable store"
mkdir -p "$store/.ledger" "$tmp/repo"
id=0123456789abcdef0123456789abcdef
printf '{"schema":"ledger-storage-root/v1","store_id":"%s"}\n' "$id" > "$store/.ledger-root.json"
root_args=(--store-root "$store" --store-id "$id")
git -C "$tmp/repo" init -q
git -C "$tmp/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
git -C "$tmp/repo" worktree add --detach "$tmp/worktree-a" >/dev/null
git -C "$tmp/repo" worktree add --detach "$tmp/worktree-b" >/dev/null
printf '{"kind":"created","value":{"id":"one","revision":1}}\n' > "$tmp/one.json"
printf '{"kind":"created","value":{"id":"two","revision":1}}\n' > "$tmp/two.json"
(cd "$tmp/worktree-a"; "$bin" transact --definition "$definition" --operation append "${root_args[@]}" --input "event=$tmp/one.json" --format json) > "$tmp/one-result.json"
(cd "$tmp/worktree-b"; "$bin" transact --definition "$definition" --operation append "${root_args[@]}" --input "event=$tmp/two.json" --format json) > "$tmp/two-result.json"
for result in one two; do
  jq -e '.valid == true and .storage_mutated == true and .semantic_authority_granted == false' "$tmp/$result-result.json" >/dev/null
done
"$bin" project --definition "$definition" --projection current "${root_args[@]}" --payload-only --format json > "$tmp/projection.json"
jq -e '.. | objects | select(.id? == "one")' "$tmp/projection.json" >/dev/null
jq -e '.. | objects | select(.id? == "two")' "$tmp/projection.json" >/dev/null
test ! -e "$tmp/worktree-a/.ledger"
test ! -e "$tmp/worktree-b/.ledger"
git -C "$tmp/repo" worktree remove "$tmp/worktree-a"
"$bin" doctor --definition "$definition" "${root_args[@]}" --format json | jq -e '.healthy == true and .pending_transactions == 0' >/dev/null

expect_failure() {
  local expected=$1
  shift
  local status=0
  "$@" > "$tmp/failure.json" 2> "$tmp/failure.stderr" || status=$?
  test "$status" -eq "$expected"
  jq -e '.storage_mutated == false and .authority_granted == false' "$tmp/failure.json" >/dev/null
}
expect_failure 3 "$bin" project --definition "$definition" --projection current --store-root "$store" --store-id wrong --format json
jq -e '.error == "StorageRootIdentityMismatch"' "$tmp/failure.json" >/dev/null
expect_failure 2 "$bin" doctor --definition "$definition" "${root_args[@]}" --repo "$tmp/repo" --format json
ln -s "$store" "$tmp/alias"
expect_failure 2 "$bin" doctor --definition "$definition" --store-root "$tmp/alias" --store-id "$id" --format json
mv "$store" "$tmp/temporarily unavailable"
expect_failure 3 "$bin" project --definition "$definition" --projection current "${root_args[@]}" --format json
test ! -e "$store"
mv "$tmp/temporarily unavailable" "$store"
rm "$store/.ledger-root.json"
expect_failure 3 "$bin" project --definition "$definition" --projection current "${root_args[@]}" --format json
# Legacy addressing remains explicit and does not require managed registration.
"$bin" doctor --definition "$definition" --repo "$store" --format json | jq -e '.healthy == true' >/dev/null
printf '%s\n' 'managed custody worktree integration: pass'
