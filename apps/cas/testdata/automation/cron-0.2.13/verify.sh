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

fail() {
  echo "cron-0.2.13 automation oracle: $*" >&2
  exit 1
}

# Create and run-now preserve the Cron row, RRULE, cwd, and synchronized-file
# semantics. Timestamps and generated IDs are checked by invariant because they
# are deliberately runtime-generated in Cron 0.2.13.
created_cwd="$oracle_root/created-cwd"
mkdir -p "$created_cwd"
created_id=$("$@" --db "$db" create \
  --name 'Oracle Created' \
  --prompt 'created prompt' \
  --rrule 'freq=daily;byhour=7;byminute=11' \
  --status PAUSED \
  --cwd "$created_cwd")
[ -n "$created_id" ] || fail "create returned an empty automation id"
created_projection=$(sqlite3 -batch -bail -noheader -separator '|' "$db" \
  "SELECT name,prompt,status,cwds,rrule,last_run_at IS NULL FROM automations WHERE id = '$created_id';")
[ "$created_projection" = "Oracle Created|created prompt|PAUSED|[\"$created_cwd\"]|RRULE:FREQ=DAILY;BYHOUR=7;BYMINUTE=11|1" ] ||
  fail "create row is not Cron-compatible"
created_dir="$HOME/.codex/automations/$created_id"
[ -f "$created_dir/automation.toml" ] || fail "create did not synchronize automation.toml"
[ -f "$created_dir/memory.md" ] || fail "create did not create memory.md"
[ ! -s "$created_dir/memory.md" ] || fail "create did not preserve empty-memory semantics"

run_now_before=$(( $(date +%s) * 1000 ))
"$@" --db "$db" run-now --id "$created_id" >/dev/null
run_now_after=$(( $(date +%s) * 1000 + 999 ))
run_now_projection=$(sqlite3 -batch -bail -noheader -separator '|' "$db" \
  "SELECT next_run_at,updated_at,last_run_at IS NULL FROM automations WHERE id = '$created_id';")
run_now_next=${run_now_projection%%|*}
run_now_rest=${run_now_projection#*|}
run_now_updated=${run_now_rest%%|*}
run_now_last_null=${run_now_rest##*|}
[ "$run_now_next" = "$run_now_updated" ] || fail "run-now did not update its exact timestamp pair"
[ "$run_now_last_null" = 1 ] || fail "run-now changed last_run_at"
[ "$run_now_next" -ge "$run_now_before" ] && [ "$run_now_next" -le "$run_now_after" ] ||
  fail "run-now timestamp is outside the invocation window"

"$@" --db "$db" delete --id "$created_id" >/dev/null
[ "$(sqlite3 -batch -bail -noheader "$db" "SELECT count(*) FROM automations WHERE id = '$created_id';")" = 0 ] ||
  fail "delete preserved the automation row"
[ ! -e "$created_dir" ] || fail "delete preserved the automation directory"

# Exercise a real due run through a deterministic fake Codex executable and
# compare the durable row projection inherited from Cron 0.2.13.
run_cwd="$oracle_root/run-cwd"
mkdir -p "$run_cwd"
"$@" --db "$db" update \
  --id cron-0.2.13-oracle \
  --prompt 'Oracle fake prompt' \
  --rrule 'freq=daily;byhour=7;byminute=11' \
  --status ACTIVE \
  --cwd "$run_cwd" \
  --clear-next-run-at >/dev/null

fake_codex="$oracle_root/fake-codex"
cat >"$fake_codex" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -ge 1 ] && [ "$1" = exec ] || exit 90
shift
output_path=
selected_cwd=
prompt=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --full-auto|--skip-git-repo-check)
      shift
      ;;
    --cd)
      [ "$#" -ge 2 ] || exit 91
      selected_cwd=$2
      shift 2
      ;;
    --output-last-message)
      [ "$#" -ge 2 ] || exit 92
      output_path=$2
      shift 2
      ;;
    *)
      [ "$#" -eq 1 ] || exit 93
      prompt=$1
      shift
      ;;
  esac
done
[ "$selected_cwd" = "${ORACLE_EXPECTED_CWD:?}" ] || exit 94
[ "$prompt" = "${ORACLE_EXPECTED_PROMPT:?}" ] || exit 95
[ -n "$output_path" ] || exit 96
printf '%s\n' 'Fake assistant output' >"$output_path"
printf '%s\n' 'fake transport stdout'
EOF
chmod +x "$fake_codex"
export ORACLE_EXPECTED_CWD="$run_cwd"
export ORACLE_EXPECTED_PROMPT='Oracle fake prompt'

actual_run_json="$oracle_root/actual-run.json"
"$@" --db "$db" run-due \
  --id cron-0.2.13-oracle \
  --codex-bin "$fake_codex" \
  --lock-label cas-automation-oracle-actual >"$actual_run_json"
grep -q '"status": "ok"' "$actual_run_json" || fail "fake Codex run did not succeed"
[ "$(sqlite3 -batch -bail -noheader "$db" \
  "SELECT count(*) FROM automation_runs WHERE automation_id='cron-0.2.13-oracle' AND status='PENDING_REVIEW';")" = 1 ] ||
  fail "actual run did not create one pending-review record"
run_thread=$(sqlite3 -batch -bail -noheader "$db" \
  "SELECT thread_id FROM automation_runs WHERE automation_id='cron-0.2.13-oracle' AND status='PENDING_REVIEW';")
[ -n "$run_thread" ] || fail "actual run record has no thread identity"
run_projection=$(sqlite3 -batch -bail -noheader -separator '|' "$db" \
  "SELECT status,source_cwd,thread_title,inbox_title,inbox_summary,archived_user_message,hex(archived_assistant_message),archived_reason FROM automation_runs WHERE thread_id='$run_thread';")
[ "$run_projection" = "PENDING_REVIEW|$run_cwd|Oracle fake prompt|Quoted \"Name\" drafted|Fake assistant output|Oracle fake prompt|46616B6520617373697374616E74206F75747075740A|headless_runner_auto_archive" ] ||
  fail "actual run record diverged from the frozen Cron projection"
run_times=$(sqlite3 -batch -bail -noheader -separator '|' "$db" \
  "SELECT last_run_at,next_run_at FROM automations WHERE id='cron-0.2.13-oracle';")
run_last=${run_times%%|*}
run_next=${run_times##*|}
[ -n "$run_last" ] && [ -n "$run_next" ] && [ "$run_next" -gt "$run_last" ] ||
  fail "actual run did not advance automation timestamps"
grep -q 'Completed 1 run(s)' "$automation_dir/memory.md" ||
  fail "actual run did not append the inherited memory summary"

# The default batch size remains ten even when more rows are due.
for limit_index in 01 02 03 04 05 06 07 08 09 10 11; do
  sqlite3 -batch -bail "$db" <<SQL
INSERT INTO automations (
  id,name,prompt,status,next_run_at,last_run_at,cwds,rrule,created_at,updated_at
) VALUES (
  'limit-$limit_index','Limit $limit_index','limit prompt','ACTIVE',
  (CAST(strftime('%s','now') AS INTEGER) * 1000) - 60000,NULL,
  '["$run_cwd"]','RRULE:FREQ=DAILY;BYHOUR=7;BYMINUTE=11',
  4102358400000,4102358400000
);
SQL
done
default_limit_json="$oracle_root/default-limit.json"
"$@" --db "$db" run-due \
  --dry-run \
  --lock-label cas-automation-oracle-limit >"$default_limit_json"
[ "$(grep -c '"status": "dry_run"' "$default_limit_json")" = 10 ] ||
  fail "run-due default limit is not ten"

# A concurrent same-label invocation is a read-only skip.
lock_label=cas-automation-oracle-lock
lock_dir="$HOME/Library/Caches/$lock_label"
mkdir -p "$lock_dir"
printf '%s\n' 'held by oracle' >"$lock_dir/run.lock"
lock_rows_before="$oracle_root/lock-rows-before.txt"
lock_rows_after="$oracle_root/lock-rows-after.txt"
logical_projection >"$lock_rows_before"
"$@" --db "$db" run-due \
  --dry-run \
  --lock-label "$lock_label" \
  >"$oracle_root/lock.stdout" 2>"$oracle_root/lock.stderr"
logical_projection >"$lock_rows_after"
cmp "$lock_rows_before" "$lock_rows_after"
[ ! -s "$oracle_root/lock.stdout" ] || fail "same-label lock wrote a run result"
grep -q 'skip: lock held' "$oracle_root/lock.stderr" ||
  fail "same-label lock was not reported"
rm -f "$lock_dir/run.lock"

# Invalid labels and incompatible stores fail before any durable mutation.
malformed_label_before="$oracle_root/malformed-label-before.txt"
malformed_label_after="$oracle_root/malformed-label-after.txt"
logical_projection >"$malformed_label_before"
if "$@" --db "$db" run-due --dry-run --lock-label '../bad' \
  >"$oracle_root/malformed-label.stdout" 2>"$oracle_root/malformed-label.stderr"; then
  fail "malformed label was accepted"
fi
logical_projection >"$malformed_label_after"
cmp "$malformed_label_before" "$malformed_label_after"
grep -q 'invalid label' "$oracle_root/malformed-label.stderr" ||
  fail "malformed label did not produce its typed diagnostic"

malformed_db="$oracle_root/malformed.db"
sqlite3 -batch -bail "$malformed_db" 'CREATE TABLE automations (id text primary key);'
cp "$malformed_db" "$oracle_root/malformed-before.db"
if "$@" --db "$malformed_db" create \
  --name 'Must Not Exist' \
  --prompt 'must not mutate' \
  --rrule 'FREQ=DAILY;BYHOUR=7;BYMINUTE=11' \
  >"$oracle_root/malformed-store.stdout" 2>"$oracle_root/malformed-store.stderr"; then
  fail "malformed store accepted a mutation"
fi
cmp "$oracle_root/malformed-before.db" "$malformed_db"
[ "$(sqlite3 -batch -bail -noheader "$malformed_db" 'SELECT count(*) FROM automations;')" = 0 ] ||
  fail "malformed store changed before rejection"
grep -q 'schema is incompatible' "$oracle_root/malformed-store.stderr" ||
  fail "malformed store did not produce its schema diagnostic"

echo "cron-0.2.13 automation oracle: pass"
