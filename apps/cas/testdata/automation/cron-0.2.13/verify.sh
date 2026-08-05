#!/bin/sh
# Frozen oracle for tag cron-v0.2.13, commit
# 90fd7ee4e5f94e95218ca13a4ae0984b1de9bd8a. Source SHA-256:
# 1198f4cb246799fc9b68142ab4f34c0626580223cffffa7ffeaaddc4c4bb2d21
set -eu

if [ "$#" -eq 0 ]; then
  echo "usage: verify.sh <command> [prefix-args ...]" >&2
  exit 2
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
oracle_root=$(mktemp -d "${TMPDIR:-/tmp}/cas-automation-oracle.XXXXXX")
touch "$oracle_root/.cas-automation-oracle-owned"
cleanup() {
  if [ -n "${oracle_root:-}" ] && [ -f "$oracle_root/.cas-automation-oracle-owned" ]; then
    rm -rf -- "$oracle_root"
  fi
}
trap cleanup EXIT HUP INT TERM

export HOME="$oracle_root/home"
db="$HOME/.codex/sqlite/codex-dev.db"
automation_dir="$HOME/.codex/automations/cron-0.2.13-oracle"
mkdir -p "$(dirname -- "$db")" "$automation_dir"
sqlite3 -batch -bail "$db" < "$script_dir/seed.sql"
cp "$script_dir/expected-memory.md" "$automation_dir/memory.md"

"$@" --db "$db" update \
  --id cron-0.2.13-oracle \
  --new-name 'Quoted "Name"' \
  --prompt 'Freeze exact "bytes" \ slash' \
  --rrule 'byminute=5;freq=weekly;byhour=6;byday=fr,mo' \
  --status PAUSED \
  --cwds-json '["/work/a","/work/space path"]' \
  --clear-next-run-at >/dev/null
"$@" --db "$db" enable --id cron-0.2.13-oracle >/dev/null
"$@" --db "$db" disable --id cron-0.2.13-oracle >/dev/null
"$@" --db "$db" enable --id cron-0.2.13-oracle >/dev/null

logical_projection() {
  sqlite3 -batch -bail -noheader "$db" <<'SQL'
SELECT 'automations|T:' || hex(id) || '|T:' || hex(name) || '|T:' || hex(prompt) ||
       '|T:' || hex(status) ||
       CASE WHEN next_run_at IS NULL THEN '|N' ELSE '|I:' || next_run_at END ||
       CASE WHEN last_run_at IS NULL THEN '|N' ELSE '|I:' || last_run_at END ||
       '|T:' || hex(cwds) || '|T:' || hex(rrule) ||
       '|I:' || created_at || '|I:' || updated_at
FROM automations ORDER BY id;
SELECT 'automation_runs|T:' || hex(thread_id) || '|T:' || hex(automation_id) ||
       '|T:' || hex(status) ||
       CASE WHEN read_at IS NULL THEN '|N' ELSE '|I:' || read_at END ||
       CASE WHEN thread_title IS NULL THEN '|N' ELSE '|T:' || hex(thread_title) END ||
       CASE WHEN source_cwd IS NULL THEN '|N' ELSE '|T:' || hex(source_cwd) END ||
       CASE WHEN inbox_title IS NULL THEN '|N' ELSE '|T:' || hex(inbox_title) END ||
       CASE WHEN inbox_summary IS NULL THEN '|N' ELSE '|T:' || hex(inbox_summary) END ||
       '|I:' || created_at || '|I:' || updated_at ||
       CASE WHEN archived_user_message IS NULL THEN '|N' ELSE '|T:' || hex(archived_user_message) END ||
       CASE WHEN archived_assistant_message IS NULL THEN '|N' ELSE '|T:' || hex(archived_assistant_message) END ||
       CASE WHEN archived_reason IS NULL THEN '|N' ELSE '|T:' || hex(archived_reason) END
FROM automation_runs ORDER BY thread_id;
SELECT 'inbox_items|T:' || hex(id) ||
       CASE WHEN title IS NULL THEN '|N' ELSE '|T:' || hex(title) END ||
       CASE WHEN description IS NULL THEN '|N' ELSE '|T:' || hex(description) END ||
       CASE WHEN thread_id IS NULL THEN '|N' ELSE '|T:' || hex(thread_id) END ||
       CASE WHEN read_at IS NULL THEN '|N' ELSE '|I:' || read_at END ||
       CASE WHEN created_at IS NULL THEN '|N' ELSE '|I:' || created_at END
FROM inbox_items ORDER BY id;
SQL
}

actual_transcript="$oracle_root/actual-transcript.txt"
list_json="$oracle_root/list.json"
show_json="$oracle_root/show.json"
sql_projection="$oracle_root/sql-projection.txt"
"$@" --db "$db" list --json > "$list_json"
"$@" --db "$db" show --id cron-0.2.13-oracle --json > "$show_json"
logical_projection > "$sql_projection"
{
  echo LIST
  cat "$list_json"
  echo SHOW
  cat "$show_json"
  echo SQL
  cat "$sql_projection"
} > "$actual_transcript"

if ! cmp -s "$script_dir/expected-transcript.txt" "$actual_transcript"; then
  diff -u "$script_dir/expected-transcript.txt" "$actual_transcript" >&2 || true
  exit 1
fi
cmp "$script_dir/expected-automation.toml" "$automation_dir/automation.toml"
cmp "$script_dir/expected-memory.md" "$automation_dir/memory.md"

rows_before="$oracle_root/rows-before.txt"
toml_before="$oracle_root/automation-before.toml"
memory_before="$oracle_root/memory-before.md"
logical_projection > "$rows_before"
cp "$automation_dir/automation.toml" "$toml_before"
cp "$automation_dir/memory.md" "$memory_before"

"$@" --db "$db" run-due \
  --id cron-0.2.13-oracle \
  --limit 1 \
  --dry-run \
  --lock-label cas-automation-parity >/dev/null

logical_projection | cmp "$rows_before" -
cmp "$toml_before" "$automation_dir/automation.toml"
cmp "$memory_before" "$automation_dir/memory.md"

echo "cron-0.2.13 automation oracle: pass"
