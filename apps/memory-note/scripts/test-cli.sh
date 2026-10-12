#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)
bin=${1:-"$repo_root/zig-out/bin/memory-note"}
bin=$(cd "$(dirname "$bin")" && printf '%s/%s' "$(pwd -P)" "$(basename "$bin")")
json=jq
if command -v jaq >/dev/null 2>&1; then json=jaq; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
fixture="$repo_root/apps/memory-note/fixtures/valid/harness-rule-input.json"
note_home="$tmp/selected home"

# The real subprocess protocol returns effective configuration, not a TOML guess.
cat > "$tmp/codex" <<'SH'
#!/bin/sh
[ "$1" = app-server ] || exit 3
[ "$CODEX_HOME" = "$EXPECTED_HOME" ] || exit 4
IFS= read -r init || exit 5
case "$init" in *'"method":"initialize"'*) ;; *) exit 6 ;; esac
printf '%s\n' '{"id":1,"result":{}}'
IFS= read -r ready || exit 7
[ "$ready" = '{"method":"initialized"}' ] || exit 8
IFS= read -r request || exit 9
case "$request" in *'"method":"config/read"'*'"cwd":"/'*) ;; *) exit 10 ;; esac
case "$FAKE_VERSION" in
  absent) printf '%s\n' '{"id":2,"result":{"config":{}}}' ;;
  null) printf '%s\n' '{"id":2,"result":{"config":{"memories":null}}}' ;;
  null-version) printf '%s\n' '{"id":2,"result":{"config":{"memories":{"version":null}}}}' ;;
  *) printf '{"id":2,"result":{"config":{"memories":{"version":"%s"}}}}\n' "$FAKE_VERSION" ;;
esac
IFS= read -r unused
SH
chmod 700 "$tmp/codex"
export CODEX_BIN="$tmp/codex" EXPECTED_HOME="$note_home" FAKE_VERSION=v2

"$bin" path --codex-home "$note_home" --extension harness --format json > "$tmp/layout.json"
"$json" -e --arg root "$note_home/memories_v2" '
  .schema == "memory-note-layout/v1" and .memory_version == "v2" and
  .memory_root == $root and .notes_dir == ($root + "/extensions/harness/notes")
' "$tmp/layout.json" >/dev/null
"$bin" path --codex-home "$note_home" --extension harness > "$tmp/path.txt"
printf '%s\n' "$note_home/memories_v2/extensions/harness/notes" > "$tmp/expected-path.txt"
cmp "$tmp/expected-path.txt" "$tmp/path.txt"
"$bin" path --codex-home "$note_home" --extension harness --format text > "$tmp/explicit-path.txt"
cmp "$tmp/path.txt" "$tmp/explicit-path.txt"
test ! -e "$note_home"

# Codex 0.162.1 ConfigToml/ApiConfig preserve absent Option fields as JSON null.
for shape in absent null null-version; do
  FAKE_VERSION="$shape" "$bin" path --codex-home "$note_home" \
    --extension harness --format json > "$tmp/default-layout.json"
  "$json" -e --arg root "$note_home/memories" \
    '.memory_version == "v1" and .memory_root == $root' "$tmp/default-layout.json" >/dev/null
done
test ! -e "$note_home"
"$bin" doctor --codex-home "$note_home" > "$tmp/doctor.json"
"$json" -e '.issues == 0 and .checked == 0 and .storage_mutated == false' \
  "$tmp/doctor.json" >/dev/null
test ! -e "$note_home"

"$bin" append --codex-home "$note_home" --extension harness \
  --kind harness-rule --json "$fixture" --dry-run > "$tmp/dry-run.json"
"$json" -e '.status == "valid_dry_run"' "$tmp/dry-run.json" >/dev/null
test ! -e "$note_home"

"$bin" append --codex-home "$note_home" --extension harness \
  --kind harness-rule --json "$fixture" > "$tmp/created.json"
"$json" -e '.status == "created"' "$tmp/created.json" >/dev/null
first_id=$("$json" -r '.id' "$tmp/created.json")
first_path=$("$json" -r '.path' "$tmp/created.json")
test -f "$first_path"
"$bin" append --codex-home "$note_home" --extension harness \
  --kind harness-rule --json "$fixture" --dry-run > "$tmp/dry-duplicate.json"
"$json" -e --arg id "$first_id" '.status == "duplicate_skip" and .id == $id' \
  "$tmp/dry-duplicate.json" >/dev/null
test ! -e "$note_home/memories"
"$bin" list --codex-home "$note_home" --extension harness > "$tmp/list.json"
"$json" -e --arg id "$first_id" '.notes | length == 1 and .[0].id == $id' \
  "$tmp/list.json" >/dev/null
"$bin" show --codex-home "$note_home" --extension harness --id "$first_id" > "$tmp/show.json"
"$json" -e --arg id "$first_id" '.id == $id and .schema == "memory-source-note/v1"' \
  "$tmp/show.json" >/dev/null
"$bin" append --codex-home "$note_home" --extension harness \
  --kind harness-rule --json "$fixture" > "$tmp/duplicate.json"
"$json" -e --arg id "$first_id" '.status == "duplicate_skip" and .id == $id' \
  "$tmp/duplicate.json" >/dev/null

# An explicit session pin wins even when the next fresh configuration selects v2.
"$json" '.summary += "; retained v1 admission"' "$fixture" > "$tmp/legacy-input.json"
"$bin" append --codex-home "$note_home" --memory-version v1 --extension harness \
  --kind harness-rule --json "$tmp/legacy-input.json" > "$tmp/legacy-created.json"
legacy_path=$("$json" -r '.path' "$tmp/legacy-created.json")
legacy_name=$(basename "$legacy_path")
legacy_dir=$(dirname "$legacy_path")
cp "$legacy_path" "$tmp/original-envelope"
# Represent a second historical admission with the same transport fingerprint.
"$json" '.id = "MSN-20260101T000000Z-aaaaaaaaaaaaaaaa" | .captured_at = "2026-01-01T00:00:00Z"' \
  "$legacy_path" > "$legacy_dir/distinct-history.md"

"$bin" migrate --codex-home "$note_home" --extension harness \
  --from-memory-version v1 --dry-run > "$tmp/preview.json"
"$json" -e '.planned == 2 and .copied == 0 and .storage_mutated == false' \
  "$tmp/preview.json" >/dev/null
test ! -e "$note_home/memories_v2/extensions/harness/notes/$legacy_name"
"$bin" migrate --codex-home "$note_home" --extension harness \
  --from-memory-version v1 > "$tmp/migrated.json"
"$json" -e '.copied == 2 and .storage_mutated == true' "$tmp/migrated.json" >/dev/null
cmp "$tmp/original-envelope" "$note_home/memories_v2/extensions/harness/notes/$legacy_name"
cmp "$legacy_dir/distinct-history.md" \
  "$note_home/memories_v2/extensions/harness/notes/distinct-history.md"
cmp "$tmp/original-envelope" "$legacy_path"
"$bin" migrate --codex-home "$note_home" --extension harness \
  --from-memory-version v1 > "$tmp/retry.json"
"$json" -e '.copied == 0 and .duplicate_skip == 2 and .storage_mutated == false' \
  "$tmp/retry.json" >/dev/null
"$bin" list --codex-home "$note_home" --extension harness > "$tmp/after.json"
"$json" -e '.notes | length == 3' "$tmp/after.json" >/dev/null

# Conflict preflight cannot overwrite an immutable target or create another note.
"$json" '.summary = "changed bytes under the same id"' "$legacy_path" > "$tmp/changed.json"
cp "$tmp/changed.json" "$legacy_path"
if "$bin" migrate --codex-home "$note_home" --extension harness \
  --from-memory-version v1 > "$tmp/conflict.out" 2> "$tmp/conflict.err"; then
  echo 'expected immutable migration conflict' >&2
  exit 1
fi
cmp "$tmp/original-envelope" "$note_home/memories_v2/extensions/harness/notes/$legacy_name"

mkdir -p "$tmp/symlink-home" "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$tmp/symlink-home/memories_v2"
if "$bin" list --codex-home "$tmp/symlink-home" --memory-version v2 --extension harness \
  > "$tmp/symlink.out" 2> "$tmp/symlink.err"; then
  echo 'expected symlink rejection' >&2
  exit 1
fi
if "$bin" doctor --codex-home "$tmp/symlink-home" --memory-version v2 \
  > "$tmp/symlink-doctor.json"; then
  echo 'expected symlink diagnostic' >&2
  exit 1
fi
"$json" -e '.issues > 0 and .extensions[0].issue == "SymlinkComponent"' \
  "$tmp/symlink-doctor.json" >/dev/null
test ! -e "$tmp/elsewhere/extensions"

export FAKE_VERSION=v3
if "$bin" path --codex-home "$note_home" --extension harness \
  > "$tmp/unknown.out" 2> "$tmp/unknown.err"; then
  echo 'expected unknown memory version rejection' >&2
  exit 1
fi
test ! -e "$note_home/memories_v2/memory_summary.md"
test ! -e "$note_home/memories_v2/MEMORY.md"
python3 "$repo_root/apps/memory-note/scripts/test_cli_recovery.py" "$bin"
python3 "$repo_root/apps/memory-note/scripts/test_cli_upgrade.py" "$bin"
printf '%s\n' 'memory-note selected-layout, immutable migration, and read-only diagnostics: pass'
