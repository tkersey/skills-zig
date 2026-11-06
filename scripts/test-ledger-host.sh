#!/usr/bin/env bash
set -Eeuo pipefail

binary=${1:?ledger binary is required}
binary=$(cd "$(dirname "$binary")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$binary")")
test -x "$binary"
json=$(command -v jaq || command -v jq)
script_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
scratch=$(mktemp -d "$temp_base/ledger-host.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'status=$?; printf "host CLI failure at line %s (exit %s)\n" "$LINENO" "$status" >&2; for file in "$scratch/result.json" "$scratch/error.txt" "$scratch/capture.json" "$scratch/projection.json"; do test ! -f "$file" || cat "$file" >&2; done; exit "$status"' ERR
export LC_ALL=C
export LEDGER_CACHE_DIR="$scratch/cache"
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
mkdir -p "$scratch/fixture"
definition="$scratch/fixture/definition.json"
manifest="$scratch/fixture/migration.json"
cp "$script_root/apps/ledger/src/v1/fixtures/event-definition.json" "$definition"
printf '%s\n' '{"schema":"ledger-owner-migration/v1","definition":"definition.json","retired_sources":[],"importer":null}' >"$manifest"

assert_json() {
  "$json" -e "$1" "${2:-$scratch/result.json}" >/dev/null
}

blocked() {
  local expected=$1
  shift
  local status=0
  "$binary" "$@" >"$scratch/result.json" 2>"$scratch/error.txt" || status=$?
  test "$status" -eq 3
  "$json" -e --arg expected "$expected" '
    .schema == "ledger-workspace-context-error/v1" and .status == "blocked" and
    .authority_granted == false and ($expected == "" or .error_code == $expected)
  ' "$scratch/result.json" >/dev/null
}

context() {
  "$binary" context "$@" >"$scratch/result.json" 2>"$scratch/error.txt"
  assert_json '.authority_granted == false'
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

snapshot() {
  if test ! -e "$1"; then
    printf '%s\n' absent
    return
  fi
  (
    cd "$1"
    find . -print | sort | while IFS= read -r path; do
      if test "$(uname -s)" = Darwin; then
        stat -f '%N|%p|%i|%z|%m|%l' "$path"
      else
        stat -c '%n|%f|%i|%s|%Y|%h' "$path"
      fi
    done
    find . -type f -size -1048576c -print | sort | while IFS= read -r path; do
      hash_file "$path"
    done
    find . -type l -print | sort | while IFS= read -r path; do
      printf '%s -> %s\n' "$path" "$(readlink "$path")"
    done
  )
}

permissions() {
  if test "$(uname -s)" = Darwin; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name Fixture
  git -C "$1" config user.email fixture@example.invalid
  printf '%s\n' '.ledger/' >"$1/.gitignore"
  git -C "$1" add .gitignore
  git -C "$1" commit -qm fixture
}

capture() {
  local root=$1 request=$2 value=$3
  printf '{"kind":"captured","value":%s}\n' "$value" >"$scratch/event.json"
  "$binary" transact --definition "$definition" --operation append --repo "$root" \
    --param "request=$request" --input "event=$scratch/event.json" --format json >"$scratch/capture.json"
  assert_json '.storage_mutated == true' "$scratch/capture.json"
}

copy_history() {
  cp -R "$1/.ledger" "$2/.ledger"
  rm -rf "$2/.ledger/.transactions"
  rm -f "$2/.ledger/.fencing.counter"
  find "$2/.ledger" -type f -name '*.cas.lock.advisory' -delete
}

project() {
  "$binary" project --definition "$definition" --projection all "$@" --format json >"$scratch/projection.json"
  "$json" -c '.data' "$scratch/projection.json"
}

printf '%s\n' 'host CLI: explicit location and read-only lookup'
mkdir -p "$scratch/read/work"
LEDGER_HOME="$scratch/ignored-ledger" CODEX_HOME="$scratch/ignored-codex" blocked MissingCatalogRoot context
test ! -e "$scratch/ignored-ledger"
test ! -e "$scratch/ignored-codex"
blocked CatalogRootNotAbsolute context --catalog-root relative --initialize
blocked UnregisteredContext context --catalog-root "$scratch/read/home" --workspace "$scratch/read/work"
test ! -e "$scratch/read/home"
context --catalog-root "$scratch/read/home" --list-stores
assert_json '.stores == [] and .storage_mutated == false'
test ! -e "$scratch/read/home"
blocked UnregisteredContext context --catalog-root "$scratch/read/home" --workspace "$scratch/read/work" --ensure
test ! -e "$scratch/read/home"
blocked SelectedStoreNotCataloged context --catalog-root "$scratch/read/home" \
  --store-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --initialize
test ! -e "$scratch/read/home"
PATH=/nonexistent "$binary" context --catalog-root "$scratch/no-git-home" \
  --workspace "$scratch/read/work" --initialize >"$scratch/result.json"
assert_json '.git_common_dir == null and .storage_mutated == true'

printf '%s\n' 'host CLI: Git family identity and explicit attachment'
family="$scratch/family"
home="$family/home"
repo="$family/main repo"
other="$family/linked worktree"
make_repo "$repo"
git -C "$repo" worktree add -q --detach "$other"
context --catalog-root "$home" --workspace "$other" --initialize
family_id=$("$json" -r '.store_id' "$scratch/result.json")
family_root=$("$json" -r '.store_root' "$scratch/result.json")
assert_json '.storage_mutated == true and (.store_id | test("^[0-9a-f]{32}$"))'
test "$(permissions "$family_root")" = 700
test "$(permissions "$family_root/.ledger-root.json")" = 600
test "$(permissions "$home/catalog.json")" = 600
printf '%s\n' shared >"$family_root/.ledger/visibility"
snapshot "$home" >"$scratch/before.snapshot"
context --catalog-root "$home" --workspace "$repo"
test "$("$json" -r '.store_id' "$scratch/result.json")" = "$family_id"
test "$("$json" -r '.workspace_root' "$scratch/result.json")" = "$repo"
assert_json '.storage_mutated == false'
test "$(cat "$family_root/.ledger/visibility")" = shared
test ! -e "$repo/.ledger"
snapshot "$home" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
git -C "$repo" worktree move "$other" "$family/moved worktree"
context --catalog-root "$home" --workspace "$family/moved worktree"
test "$("$json" -r '.store_id' "$scratch/result.json")" = "$family_id"
git -C "$repo" worktree remove "$family/moved worktree"
blocked GitCommonDirectoryIdentityChanged context --catalog-root "$home" --workspace "$other"
make_repo "$other"
blocked UnregisteredGitCommonDirectory context --catalog-root "$home" --workspace "$other" --initialize
context --catalog-root "$home" --workspace "$other" --store-id "$family_id" --attach-workspace
context --catalog-root "$home" --workspace "$other"
test "$("$json" -r '.store_id' "$scratch/result.json")" = "$family_id"
mkdir -p "$family/plain"
context --catalog-root "$home" --workspace "$family/plain" --store-id "$family_id" --attach-workspace
context --catalog-root "$home" --workspace "$family/plain"
git -C "$family/plain" init -q
blocked UnregisteredGitCommonDirectory context --catalog-root "$home" --workspace "$family/plain"
context --catalog-root "$home" --workspace "$family/plain" --store-id "$family_id" --attach-workspace
git clone -q "$repo" "$family/clone"
context --catalog-root "$home" --workspace "$family/clone" --initialize
clone_id=$("$json" -r '.store_id' "$scratch/result.json")
test "$clone_id" != "$family_id"
blocked ConflictingWorkspaceAssociations context --catalog-root "$home" --workspace "$repo" \
  --store-id "$clone_id" --attach-workspace
blocked SelectedStoreNotCataloged context --catalog-root "$family/another-home" --store-id "$family_id" --initialize
test ! -e "$family/another-home"
rm -rf "$repo" "$other" "$family/clone"
context --catalog-root "$home" --store-id "$family_id"
PATH=/nonexistent "$binary" context --catalog-root "$home" --store-id "$family_id" >"$scratch/result.json"
test "$("$json" -r '.store_root' "$scratch/result.json")" = "$family_root"
context --catalog-root "$home" --list-stores
assert_json '.stores | length == 2'

printf '%s\n' 'host CLI: concurrent initialization'
mkdir -p "$scratch/concurrent/work"
pids=()
for index in 1 2 3 4 5 6 7 8; do
  "$binary" context --catalog-root "$scratch/concurrent/home" --workspace "$scratch/concurrent/work" \
    --initialize >"$scratch/concurrent/$index.json" 2>"$scratch/concurrent/$index.err" &
  pids+=("$!")
done
concurrent_failed=0
for pid in "${pids[@]}"; do wait "$pid" || concurrent_failed=1; done
if test "$concurrent_failed" -ne 0; then
  cat "$scratch/concurrent/"[1-8].json "$scratch/concurrent/"[1-8].err >&2
  exit 1
fi
test "$("$json" -r '.store_id' "$scratch/concurrent/"[1-8].json | sort -u | wc -l | tr -d ' ')" = 1
test "$(find "$scratch/concurrent/home/repos" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1

printf '%s\n' 'host CLI: malformed metadata and vanished custody fail closed'
guards="$scratch/guards"
mkdir -p "$guards/work"
context --catalog-root "$guards/home" --workspace "$guards/work" --initialize
guard_id=$("$json" -r '.store_id' "$scratch/result.json")
guard_root=$("$json" -r '.store_root' "$scratch/result.json")
cp "$guards/home/catalog.json" "$guards/catalog.saved"
cp "$guard_root/.ledger-root.json" "$guards/marker.saved"
for malformed in '{broken' '{}' '{"schema":"bad","schema":"duplicate","stores":{},"aliases":{}}'; do
  printf '%s\n' "$malformed" >"$guards/home/catalog.json"
  cp "$guards/home/catalog.json" "$guards/corrupt.saved"
  blocked '' context --catalog-root "$guards/home" --workspace "$guards/work" --initialize
  cmp "$guards/corrupt.saved" "$guards/home/catalog.json"
done
dd if=/dev/zero of="$guards/home/catalog.json" bs=1048577 count=1 2>/dev/null
cp "$guards/home/catalog.json" "$guards/corrupt.saved"
blocked '' context --catalog-root "$guards/home" --store-id "$guard_id"
cmp "$guards/corrupt.saved" "$guards/home/catalog.json"
cp "$guards/catalog.saved" "$guards/home/catalog.json"
rm "$guards/home/catalog.json"
ln -s "$guards/catalog.saved" "$guards/home/catalog.json"
blocked '' context --catalog-root "$guards/home" --store-id "$guard_id"
test -L "$guards/home/catalog.json"
rm "$guards/home/catalog.json"
cp "$guards/catalog.saved" "$guards/home/catalog.json"
for marker in '{"schema":"ledger-storage-root/v1","store_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' \
  '{"schema":"ledger-storage-root/v1","store_id":"bad","store_id":"duplicate"}'; do
  printf '%s\n' "$marker" >"$guard_root/.ledger-root.json"
  blocked '' context --catalog-root "$guards/home" --workspace "$guards/work" --initialize
done
cp "$guards/marker.saved" "$guard_root/.ledger-root.json"
mv "$guard_root/.ledger" "$guard_root/control.saved"
blocked StorageRootMissing context --catalog-root "$guards/home" --workspace "$guards/work" --initialize
test ! -e "$guard_root/.ledger"
mv "$guard_root/control.saved" "$guard_root/.ledger"
mv "$guard_root" "$guard_root.saved"
blocked StorageRootMissing context --catalog-root "$guards/home" --workspace "$guards/work" --initialize
test ! -e "$guard_root"
ln -s "$guard_root.saved" "$guard_root"
blocked '' context --catalog-root "$guards/home" --workspace "$guards/work"
rm "$guard_root"
mv "$guard_root.saved" "$guard_root"
ln -s "$guards/home" "$guards/linked-home"
blocked '' context --catalog-root "$guards/linked-home" --workspace "$guards/work" --initialize
rm "$guards/home/catalog.json"
blocked ExistingCustodyWithoutCatalog context --catalog-root "$guards/home" --workspace "$guards/work" --initialize
context --catalog-root "$guards/home" --workspace "$guards/work" --register-root "$guard_root" --store-id "$guard_id"
cmp "$guards/marker.saved" "$guard_root/.ledger-root.json"

printf '%s\n' 'host CLI: authorized registration import and conflicts'
registration="$scratch/registration"
make_repo "$registration/repo"
git -C "$registration/repo" worktree add -q --detach "$registration/other"
context --catalog-root "$registration/seed" --initialize
registered_id=$("$json" -r '.store_id' "$scratch/result.json")
registered_root=$("$json" -r '.store_root' "$scratch/result.json")
printf '%s\n' preserved >"$registered_root/.ledger/opaque"
"$json" -n --arg id "$registered_id" --arg root "$registered_root" \
  '{schema:"ledger-repository-registration/v1",store_id:$id,store_root:$root}' \
  >"$registration/repo/.git/ledger-store.json"
cp "$registration/repo/.git/ledger-store.json" "$registration/registration.saved"
snapshot "$registered_root" >"$scratch/before.snapshot"
blocked UnregisteredContext context --catalog-root "$registration/home" --workspace "$registration/repo"
blocked ExistingRegistrationRequiresImport context --catalog-root "$registration/home" --workspace "$registration/repo" --initialize
test ! -e "$registration/home"
rm -rf "$registration/other"
context --catalog-root "$registration/home" --workspace "$registration/repo" --ensure
test "$("$json" -r '.store_id' "$scratch/result.json")" = "$registered_id"
assert_json '.storage_mutated == true'
context --catalog-root "$registration/home" --workspace "$registration/repo" --ensure
assert_json '.storage_mutated == false'
snapshot "$registered_root" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
cmp "$registration/registration.saved" "$registration/repo/.git/ledger-store.json"
context --catalog-root "$registration/imported" --import-registration "$registration/registration.saved"
test "$("$json" -r '.store_id' "$scratch/result.json")" = "$registered_id"
cp -R "$registered_root" "$registration/copied-root"
blocked StoreAlreadyCatalogedAtAnotherRoot context --catalog-root "$registration/home" \
  --register-root "$registration/copied-root" --store-id "$registered_id"
context --catalog-root "$registration/seed" --initialize
replacement_id=$("$json" -r '.store_id' "$scratch/result.json")
replacement_root=$("$json" -r '.store_root' "$scratch/result.json")
blocked DifferentLegacyRegistration context --catalog-root "$registration/home" --workspace "$registration/repo" \
  --register-root "$replacement_root" --store-id "$replacement_id"
printf '%s\n' '{broken' >"$registration/repo/.git/ledger-store.json"
blocked '' context --catalog-root "$registration/invalid-home" --workspace "$registration/repo" --ensure
test ! -e "$registration/invalid-home/catalog.json"
cp "$registration/registration.saved" "$registration/repo/.git/ledger-store.json"

printf '%s\n' 'host CLI: cold adoption copies complete native history'
cold="$scratch/cold"
make_repo "$cold/repo"
git -C "$cold/repo" worktree add -q --detach "$cold/other"
capture "$cold/repo" cold-one 1
copy_history "$cold/repo" "$cold/other"
capture "$cold/repo" cold-two 2
project --repo "$cold/repo" >"$scratch/source-projection.json"
blocked AdoptionSourceDoesNotCoverHistory context --catalog-root "$cold/home" --workspace "$cold/other" --initialize \
  --adopt-from "$cold/other" --definition "$definition" --confirm-no-legacy-writers
test ! -e "$cold/home"
printf '%s\n' unknown >"$cold/repo/.ledger/uncovered"
blocked UncoveredLegacyFile context --catalog-root "$cold/home" --workspace "$cold/repo" --initialize \
  --adopt-from "$cold/repo" --definition "$definition" --confirm-no-legacy-writers
test ! -e "$cold/home"
rm "$cold/repo/.ledger/uncovered"
blocked '' context --catalog-root "$cold/home" --workspace "$cold/repo" --initialize \
  --adopt-from "$cold/repo" --definition "$definition"
test ! -e "$cold/home"
snapshot "$cold/repo/.ledger" >"$scratch/before.snapshot"
context --catalog-root "$cold/home" --workspace "$cold/other" --initialize \
  --adopt-from "$cold/repo" --definition "$definition" --confirm-no-legacy-writers
cold_id=$("$json" -r '.store_id' "$scratch/result.json")
cold_root=$("$json" -r '.store_root' "$scratch/result.json")
project --store-root "$cold_root" --store-id "$cold_id" >"$scratch/adopted-projection.json"
cmp "$scratch/source-projection.json" "$scratch/adopted-projection.json"
snapshot "$cold/repo/.ledger" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
test ! -e "$cold_root/.ledger/example/events.jsonl.cas.lock.advisory"

printf '%s\n' 'host CLI: selected owner preparation ignores unrelated large history'
owner="$scratch/owner"
make_repo "$owner/repo"
git -C "$owner/repo" worktree add -q --detach "$owner/prefix"
capture "$owner/repo" owner-one 1
copy_history "$owner/repo" "$owner/prefix"
capture "$owner/repo" owner-two 2
mkdir -p "$owner/repo/.ledger/unrelated"
dd if=/dev/null of="$owner/repo/.ledger/unrelated/sparse.bin" bs=1 count=0 seek=2147483649 2>/dev/null
snapshot "$owner" >"$scratch/before.snapshot"
blocked OwnerPreparationRequired context --catalog-root "$owner/home" --workspace "$owner/repo" \
  --definition "$definition" --owner-manifest "$manifest" --read-only
snapshot "$owner" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
context --catalog-root "$owner/home" --workspace "$owner/repo" --definition "$definition" \
  --owner-manifest "$manifest" --ensure-owner --confirm-no-legacy-writers
owner_id=$("$json" -r '.store_id' "$scratch/result.json")
owner_root=$("$json" -r '.store_root' "$scratch/result.json")
test ! -e "$owner_root/.ledger/unrelated"
test -f "$owner/repo/.ledger/unrelated/sparse.bin"
project --store-root "$owner_root" --store-id "$owner_id" >"$scratch/owner-projection.json"
assert_json 'length == 2' "$scratch/owner-projection.json"
snapshot "$owner" >"$scratch/before.snapshot"
context --catalog-root "$owner/home" --workspace "$owner/prefix" \
  --definition "$definition" --owner-manifest "$manifest" --read-only
assert_json '.source_coverage == "not_checked" and .owner_health.healthy and .authority_granted == false'
blocked PreparationRequiresQuiescence context --catalog-root "$owner/home" \
  --workspace "$owner/prefix" --definition "$definition" --owner-manifest "$manifest" --ensure-owner
snapshot "$owner" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
while IFS= read -r advisory; do
  relative=${advisory#"$owner/repo/.ledger/"}
  mkdir -p "$(dirname "$owner/prefix/.ledger/$relative")"
  cp "$advisory" "$owner/prefix/.ledger/$relative"
done < <(find "$owner/repo/.ledger" -type f -name '*.cas.lock.advisory')
snapshot "$owner" >"$scratch/before.snapshot"
context --catalog-root "$owner/home" --workspace "$owner/prefix" --definition "$definition" \
  --owner-manifest "$manifest" --read-only
assert_json '.storage_mutated == false'
snapshot "$owner" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
rm "$owner_root/.ledger/example/events.jsonl"
context --catalog-root "$owner/home" --workspace "$owner/repo" --definition "$definition" \
  --owner-manifest "$manifest" --ensure-owner --confirm-no-legacy-writers
test "$("$json" -r '.store_id' "$scratch/result.json")" = "$owner_id"
project --store-root "$owner_root" --store-id "$owner_id" >"$scratch/restored-projection.json"
cmp "$scratch/owner-projection.json" "$scratch/restored-projection.json"
capture "$owner/prefix" owner-divergent 999
snapshot "$owner_root" >"$scratch/before.snapshot"
context --catalog-root "$owner/home" --workspace "$owner/prefix" \
  --definition "$definition" --owner-manifest "$manifest" --read-only
assert_json '.source_coverage == "not_checked" and .owner_health.healthy and .storage_mutated == false'
snapshot "$owner_root" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
cp "$owner_root/.ledger/example/events.jsonl" "$scratch/retained-events.jsonl"
blocked '' context --catalog-root "$owner/home" --workspace "$owner/prefix" --definition "$definition" \
  --owner-manifest "$manifest" --ensure-owner --confirm-no-legacy-writers
cmp "$scratch/retained-events.jsonl" "$owner_root/.ledger/example/events.jsonl"

mv "$owner/prefix" "$owner/prefix-unavailable"
snapshot "$owner_root" >"$scratch/before.snapshot"
context --catalog-root "$owner/home" --workspace "$owner/repo" \
  --definition "$definition" --owner-manifest "$manifest" --read-only
assert_json '.source_coverage == "not_checked" and .owner_health.healthy and .storage_mutated == false'
workspace_revision=$("$json" -r '.owner_health.slots[0].revision' "$scratch/result.json")
context --catalog-root "$owner/home" --store-id "$owner_id" \
  --definition "$definition" --owner-manifest "$manifest" --read-only
test "$("$json" -r '.owner_health.slots[0].revision' "$scratch/result.json")" = "$workspace_revision"
blocked UnavailableWorktree context --catalog-root "$owner/home" --workspace "$owner/repo" \
  --definition "$definition" --owner-manifest "$manifest" --ensure-owner --confirm-no-legacy-writers
snapshot "$owner_root" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
mv "$owner/prefix-unavailable" "$owner/prefix"

printf '%s\n' 'host CLI: healthy segmented history and unsupported preparation'
segmented="$scratch/segmented"
mkdir -p "$segmented/owner" "$segmented/work" "$segmented/unknown"
"$json" '.storage.slots.events.layout = "segmented" |
  .storage.slots.events.max_bytes = 67108864 |
  del(.operations.append.effects[0].idempotency_param)' \
  "$script_root/apps/ledger/src/v1/fixtures/chained-event-definition.json" >"$segmented/owner/definition.json"
printf '%s\n' '{"schema":"ledger-owner-migration/v1","definition":"definition.json","retired_sources":[],"importer":null}' \
  >"$segmented/owner/migration.json"
context --catalog-root "$segmented/home" --workspace "$segmented/work" --initialize
segmented_id=$("$json" -r '.store_id' "$scratch/result.json")
segmented_root=$("$json" -r '.store_root' "$scratch/result.json")
"$binary" transact --definition "$segmented/owner/definition.json" --operation append \
  --store-root "$segmented_root" --store-id "$segmented_id" \
  --input "event=$script_root/apps/ledger/src/v1/fixtures/chained-event-one.json" \
  --format json >"$scratch/capture.json"
assert_json '.storage_mutated == true' "$scratch/capture.json"
mkdir -p "$segmented_root/legacy-archive/broken"
printf '%s\n' 'malformed archive must not be read' >"$segmented_root/legacy-archive/broken/manifest.json"
snapshot "$segmented/home" >"$scratch/before.snapshot"
blocked PreparationRequiresQuiescence context --catalog-root "$segmented/home" \
  --workspace "$segmented/work" --ensure-owner --definition "$segmented/owner/definition.json" \
  --owner-manifest "$segmented/owner/migration.json"
context --catalog-root "$segmented/home" --workspace "$segmented/work" --read-only \
  --definition "$segmented/owner/definition.json" --owner-manifest "$segmented/owner/migration.json"
assert_json '.source_coverage == "not_checked" and .owner_health.healthy and .storage_mutated == false'
test ! -e "$segmented/work/.ledger"
context --catalog-root "$segmented/home" --workspace "$segmented/work" --ensure-owner \
  --confirm-no-legacy-writers --definition "$segmented/owner/definition.json" \
  --owner-manifest "$segmented/owner/migration.json"
while IFS= read -r guard; do
  relative="${guard#"$segmented_root/.ledger/"}"
  mkdir -p "$(dirname "$segmented/work/.ledger/$relative")"
  cp "$guard" "$segmented/work/.ledger/$relative"
done < <(find "$segmented_root/.ledger" -type f -name '*.cas.lock.advisory')
for mode in --ensure-owner --read-only; do
  context --catalog-root "$segmented/home" --workspace "$segmented/work" "$mode" \
    --definition "$segmented/owner/definition.json" --owner-manifest "$segmented/owner/migration.json"
  test "$("$json" -r '.store_id' "$scratch/result.json")" = "$segmented_id"
  assert_json 'has("preparation") | not'
done
snapshot "$segmented/home" >"$scratch/after.snapshot"
cmp "$scratch/before.snapshot" "$scratch/after.snapshot"
blocked UnsupportedPreparationLayout context --catalog-root "$segmented/unknown-home" \
  --workspace "$segmented/unknown" --ensure-owner --definition "$segmented/owner/definition.json" \
  --owner-manifest "$segmented/owner/migration.json"
test ! -e "$segmented/unknown-home"

printf '%s\n' 'host CLI regression checks passed'
