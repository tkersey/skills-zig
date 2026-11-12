#!/usr/bin/env bash
set -euo pipefail
trap 'printf "observation contract check failed at line %s\n" "$LINENO" >&2' ERR

binary=$1
repo_root=$(pwd -P)
message_definition=apps/seq/src/v1/fixtures/message-observation.json
lineage_definition=apps/seq/src/v1/fixtures/lineage-observation.json
rollout=apps/seq/src/v1/fixtures/rollout.jsonl
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
work=$(mktemp -d "$temp_base/seq-observation-contract.XXXXXX")
trap 'test -n "${work:-}" && rm -rf -- "$work"' EXIT
export SEQ_CACHE_DIR="$work/cache"

jq '.selectors = ["path", "root", "session-id", "repo", "since", "until", "last"]' \
  "$message_definition" >"$work/message.json"
within=$("$binary" observe --definition "$work/message.json" --projection rows \
  --path "$rollout" --since 2026-07-26T10:00:02Z --param needle=failure --format json)
outside=$("$binary" observe --definition "$work/message.json" --projection rows \
  --path "$rollout" --since 2026-07-26T10:00:03Z --param needle=failure --format json)
jq -e --arg version "$(tr -d '[:space:]' <apps/seq/VERSION)" \
  --arg path "$repo_root/$rollout" '
  .schema == "seq-observation-result/v2" and .seq_version == $version and
  .selection.path == $path and .selection.root == null and
  .selection.root_explicit == false and .selection.since_ms != null and
  .selection.until_ms == null and .context.as_of_ms > 0 and
  .context.as_of_ms < 9007199254740992 and .context.ongoing_threshold_secs == 60 and
  (.context.source_metadata_digest | startswith("sha256:")) and
  .corpus.parser_warning_count == 0 and .corpus.semantic_contamination == "not_assessed" and
  (.corpus | has("contaminated") | not) and
  .stats.discovery_files_opened == 0 and .stats.discovery_bytes_read == 0 and
  .stats.corpus_bytes_read == .stats.bytes_read' <<<"$within" >/dev/null
printf '%s\n' "$within" "$outside" | jq -se '
  .[0].definition.digest == .[1].definition.digest and
  .[0].corpus.digest == .[1].corpus.digest and
  .[0].parameters_digest == .[1].parameters_digest and
  .[0].selection_digest != .[1].selection_digest and
  (.[0].data.rows | length) == 1 and (.[1].data.rows | length) == 0' >/dev/null

equivalent=$("$binary" observe --definition "$work/message.json" --projection rows \
  --path "$repo_root/apps/seq/src/v1/fixtures/../fixtures/rollout.jsonl" \
  --since 2026-07-26T03:00:02-07:00 --param needle=failure --format json)
printf '%s\n' "$within" "$equivalent" | jq -se '
  .[0].selection == .[1].selection and
  .[0].selection_digest == .[1].selection_digest' >/dev/null
relative=$("$binary" observe --definition "$work/message.json" --projection rows \
  --path "$rollout" --last 1h --param needle=failure --format json)
jq -e '.selection.since_ms != null and .selection.until_ms != null and
  (.selection.until_ms - .selection.since_ms) == 3600000' <<<"$relative" >/dev/null
empty_parameter=$("$binary" observe --definition "$message_definition" --projection rows \
  --path "$rollout" --param needle= --format json)
jq -e '(.data.rows | length) == 1' <<<"$empty_parameter" >/dev/null

jq '.relations = [{name:"sessions", fields:["session_id"]}]' \
  apps/seq/src/v1/fixtures/external-observation.json >"$work/external.json"
external=$(env -u HOME -u CODEX_HOME "$binary" observe --definition "$work/external.json" \
  --input facts=apps/seq/src/v1/fixtures/external-facts.json --projection rows --format json)
jq -e '.selection.root == null and .selection.path == null and
  .selection.root_explicit == false and .stats.discovery_files_opened == 0 and
  .corpus.adapter == "immutable-relation-json/v1"' <<<"$external" >/dev/null

jq -c 'if .payload.type == "agent_message" then
  .payload.message = "Quoted audit prompt: use $seq and report a successful audit" else . end' \
  "$rollout" >"$work/audit.jsonl"
audit=$("$binary" observe --definition "$message_definition" --projection rows \
  --path "$work/audit.jsonl" --param needle=audit --format json)
jq -e '.corpus.parser_warning_count == 0 and .corpus.semantic_contamination == "not_assessed"
  and (.data.rows | length) == 1' <<<"$audit" >/dev/null
printf '%s\n' 'not JSON' >>"$work/audit.jsonl"
warning=$("$binary" observe --definition "$message_definition" --projection rows \
  --path "$work/audit.jsonl" --param needle=audit --format json)
jq -e '.corpus.parser_warning_count > 0 and .corpus.semantic_contamination == "not_assessed"
  and (.limitations | any(contains("parser warnings")))' <<<"$warning" >/dev/null

jq '
  .id = "example/session-freshness" |
  .requires.operators = ["scan"] | .parameters = {} | .selectors = ["path"] |
  .relations = [{name:"sessions", fields:["session_id", "is_ongoing", "status_reason"]}] |
  .pipeline = [{op:"scan", relation:"sessions", as:"rows"}] |
  .projections.rows.fields = ["session_id", "is_ongoing", "status_reason"]
' "$message_definition" >"$work/freshness.json"
jq -c 'select(.payload.type != "task_complete")' "$rollout" >"$work/open.jsonl"
fresh=$("$binary" observe --definition "$work/freshness.json" --projection rows \
  --path "$work/open.jsonl" --format json)
touch -t 200001010000 "$work/open.jsonl"
stale=$("$binary" observe --definition "$work/freshness.json" --projection rows \
  --path "$work/open.jsonl" --format json)
printf '%s\n' "$fresh" "$stale" | jq -se '
  .[0].corpus.digest == .[1].corpus.digest and
  .[0].selection_digest == .[1].selection_digest and
  .[0].context.source_metadata_digest != .[1].context.source_metadata_digest and
  .[0].data.rows[0].is_ongoing == true and .[1].data.rows[0].is_ongoing == false' >/dev/null

mkdir -p "$work/codex/sessions"
cp "$rollout" "$work/codex/sessions/one.jsonl"
jq -c 'if .type == "session_meta" then .payload.id = "fixture-two" else . end' \
  "$rollout" >"$work/codex/sessions/two.jsonl"
bytes=$(( $(wc -c <"$work/codex/sessions/one.jsonl") + $(wc -c <"$work/codex/sessions/two.jsonl") ))
jq --argjson bound "$((bytes - 1))" '.bounds.max_input_bytes = $bound' \
  "$lineage_definition" >"$work/lineage.json"
explanation=$("$binary" explain --definition "$work/lineage.json" --projection rows --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$explanation" >/dev/null
if exceeded=$("$binary" observe --definition "$work/lineage.json" --projection rows \
  --root "$work/codex/sessions" --format json 2>&1); then
  echo "streaming observation accepted an aggregate corpus above its byte bound" >&2
  exit 1
fi
jq -e '.code == "ObservationInputByteBoundExceeded"' <<<"$exceeded" >/dev/null

for bound in "$bytes" "$((bytes + 1))"; do
  jq --argjson bound "$bound" '.bounds.max_input_bytes = $bound' \
    "$lineage_definition" >"$work/lineage.json"
  exact=$("$binary" observe --definition "$work/lineage.json" --projection rows \
    --root "$work/codex/sessions" --format json)
  jq -e --argjson bytes "$bytes" '.corpus.files == 2 and (.data.rows | length) == 2 and
    .stats.files_opened == 4 and .stats.discovery_files_opened == 2 and
    .stats.corpus_bytes_read == $bytes and .stats.discovery_bytes_read == $bytes and
    .stats.bytes_read == ($bytes * 2) and .stats.physical_passes == 1' <<<"$exact" >/dev/null
done
implicit=$(CODEX_HOME="$work/codex" "$binary" observe \
  --definition "$work/lineage.json" --projection rows --format json)
printf '%s\n' "$exact" "$implicit" | jq -se '
  .[0].selection.root == .[1].selection.root and
  .[0].selection.root_explicit == true and .[1].selection.root_explicit == false and
  .[0].selection_digest != .[1].selection_digest and .[0].data == .[1].data' >/dev/null

jq -c 'if .type == "session_meta" then
  .payload.id = "fixture-outside" | .payload.cwd = "/other" else . end' \
  "$rollout" >"$work/codex/sessions/other.jsonl"
selected_repo=$("$binary" observe --definition "$work/lineage.json" --projection rows \
  --root "$work/codex/sessions" --repo /repo --format json)
jq -e --argjson bytes "$bytes" '.corpus.files == 2 and (.data.rows | length) == 2 and
  .stats.files_opened == 5 and .stats.discovery_files_opened == 3 and
  .stats.corpus_bytes_read == $bytes' <<<"$selected_repo" >/dev/null
touch -t 200101010000 "$work/codex/sessions/other.jsonl"
touched_repo=$("$binary" observe --definition "$work/lineage.json" --projection rows \
  --root "$work/codex/sessions" --repo /repo --format json)
jq -e -s '.[0].context.source_metadata_digest == .[1].context.source_metadata_digest' \
  <<<"$selected_repo$touched_repo" >/dev/null

mkdir -p "$work/compressed/sessions" "$work/compressed/archived_sessions"
cp apps/seq/testdata/rollout.jsonl.zst \
  "$work/compressed/archived_sessions/old.jsonl.zst"
jq -c 'if .type == "session_meta" then .payload.id = "fixture-live" else . end' \
  "$rollout" >"$work/compressed/sessions/live.jsonl"
decoded_bytes=$(( $(wc -c <"$rollout") + $(wc -c <"$work/compressed/sessions/live.jsonl") ))
jq --argjson bound "$decoded_bytes" '.bounds.max_input_bytes = $bound' \
  "$lineage_definition" >"$work/compressed-lineage.json"
compressed=$(CODEX_HOME="$work/compressed" "$binary" observe \
  --definition "$work/compressed-lineage.json" --projection rows --format json)
jq -e --arg root "$work/compressed" --argjson bytes "$decoded_bytes" '
  .selection.root == ($root + "/sessions") and
  .selection.archive_root == ($root + "/archived_sessions") and
  .selection.root_explicit == false and .corpus.files == 2 and
  (.data.rows | length) == 2 and .corpus.parser_warning_count == 0 and
  .stats.corpus_bytes_read == $bytes' <<<"$compressed" >/dev/null
limited=$(CODEX_HOME="$work/compressed" "$binary" observe \
  --definition "$work/compressed-lineage.json" --root "$work/compressed/sessions" \
  --projection rows --format json)
jq -e '.selection.archive_root == null and .selection.root_explicit and
  .corpus.files == 1 and (.data.rows | length) == 1' <<<"$limited" >/dev/null
jq --argjson bound "$((decoded_bytes - 1))" '.bounds.max_input_bytes = $bound' \
  "$lineage_definition" >"$work/compressed-lineage.json"
if exceeded=$(CODEX_HOME="$work/compressed" "$binary" observe \
  --definition "$work/compressed-lineage.json" --projection rows --format json); then
  exit 1
fi
jq -e '.code == "ObservationInputByteBoundExceeded"' <<<"$exceeded" >/dev/null

native_archive=$(CODEX_HOME="$work/compressed" "$binary" sessions --format json)
jq -e 'length == 2 and any(.[]; .session_id == "fixture-session") and
  any(.[]; .session_id == "fixture-live")' <<<"$native_archive" >/dev/null
archive_index=$(CODEX_HOME="$work/compressed" "$binary" index status --format json)
jq -e --arg root "$work/compressed" '.files == 2 and
  .archive_root == ($root + "/archived_sessions")' <<<"$archive_index" >/dev/null

mkdir -p "$work/atomic"
jq -cn '{type:"session_meta",payload:{id:"large",thread_name:("x" * 12000)}}' \
  >"$work/atomic/a-valid.jsonl"
printf '%s\n' '{bad-json' >"$work/atomic/b-invalid.jsonl"
if "$binary" sessions --root "$work/atomic" --format json >"$work/error.json"; then
  exit 1
fi
jq -se 'length == 1 and (.[0] | .schema == "seq-command-error/v1" and
  .code == "PhysicalSourceWarningsPresent" and .warning_count == 1 and
  (.path | endswith("b-invalid.jsonl")) and (.message | length > 0))' \
  "$work/error.json" >/dev/null

mkdir -p "$work/claude"
printf '%s\n' '{"type":"user","uuid":"u","sessionId":"claude","message":{"role":"user","content":"hello"}}' \
  >"$work/claude/transcript.jsonl"
if unsupported=$("$binary" sessions --root "$work/claude" --format json); then
  exit 1
fi
jq -e '.code == "UnsupportedSessionFormat"' <<<"$unsupported" >/dev/null

mkdir -p "$work/failed-selection"
printf '%s\n' 'not zstd' >"$work/failed-selection/a-invalid.jsonl.zst"
cp "$work/claude/transcript.jsonl" "$work/failed-selection/b-claude.jsonl"
if failed_selection=$("$binary" find-session --root "$work/failed-selection" \
  --session-id missing --format json); then
  exit 1
fi
jq -e '.code == "InvalidCompressedSession" and .message == "InvalidCompressedSession" and
  (.path | endswith("a-invalid.jsonl.zst"))' <<<"$failed_selection" >/dev/null
if failed_detail=$("$binary" session-detail \
  --path "$work/failed-selection/a-invalid.jsonl.zst" --format json); then
  exit 1
fi
jq -e '.code == "InvalidCompressedSession" and .message == "InvalidCompressedSession" and
  (.path | endswith("a-invalid.jsonl.zst"))' <<<"$failed_detail" >/dev/null
if failed_graph=$("$binary" session-graph --root "$work/failed-selection" --format dot); then
  exit 1
fi
jq -e '.code == "InvalidCompressedSession" and .message == "InvalidCompressedSession" and
  (.path | endswith("a-invalid.jsonl.zst"))' <<<"$failed_graph" >/dev/null
if unsupported=$("$binary" observe --definition "$message_definition" \
  --path "$work/claude/transcript.jsonl" --param needle=hello --projection rows --format json); then
  exit 1
fi
jq -e '.code == "UnsupportedSessionFormat"' <<<"$unsupported" >/dev/null

mkdir -p "$work/linear-root"
cp "$rollout" "$work/linear-root/inside.jsonl"
{
  jq -c 'if .type == "session_meta" then
    .payload.id = "fixture-other" | .payload.cwd = "/other" else . end' "$rollout"
  for _ in 1 2 3 4; do jq -c 'select(.type != "session_meta")' "$rollout"; done
} >"$work/linear-root/other.jsonl"
inside_bytes=$(wc -c <"$work/linear-root/inside.jsonl")
jq --argjson bound "$((inside_bytes + 1))" '.bounds.max_input_bytes = $bound' \
  "$work/message.json" >"$work/linear-bound.json"
linear_repo=$("$binary" observe --definition "$work/linear-bound.json" --projection rows \
  --root "$work/linear-root" --repo /repo --param needle=failure --format json)
jq -e --argjson bytes "$inside_bytes" '.corpus.files == 1 and
  .stats.corpus_bytes_read == $bytes and .stats.discovery_files_opened == 1 and
  .stats.files_opened == 2' <<<"$linear_repo" >/dev/null

mkdir -p "$work/aborted-root"
cp "$rollout" "$work/aborted-root/one.jsonl"
: >"$work/aborted-root/aborted.jsonl"
aborted_lineage=$("$binary" observe --definition "$lineage_definition" --projection rows \
  --root "$work/aborted-root" --format json)
jq -e '(.data.rows | length) == 1' <<<"$aborted_lineage" >/dev/null
aborted_reachability=$("$binary" observe \
  --definition apps/seq/src/v1/fixtures/pi/graph-observation.json --projection rows \
  --root "$work/aborted-root" --format json)
jq -e '(.data.rows | map(.session_id) | sort) == [null, "fixture-session"]' \
  <<<"$aborted_reachability" >/dev/null

extra_scan_definition=apps/seq/src/v1/fixtures/lineage-extra-scan.json
extra_plan=$("$binary" explain --definition "$extra_scan_definition" --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$extra_plan" >/dev/null
extra_scan=$("$binary" observe --definition "$extra_scan_definition" --projection rows \
  --root "$work/aborted-root" --format json)
jq -e '(.data.rows | length) == 1' <<<"$extra_scan" >/dev/null

jq '.requires.operators += ["limit"] |
  .pipeline += [{op:"limit", input:"owned_rows", as:"bounded_rows", limit:1}] |
  .projections.rows.relation = "bounded_rows"' "$lineage_definition" >"$work/lineage-limit.json"
bounded=$("$binary" observe --definition "$work/lineage-limit.json" --projection rows \
  --root "$work/aborted-root" --format json)
jq -e '.limitations | any(contains("definition-bounded"))' <<<"$bounded" >/dev/null

if not_utf8=$("$binary" observe --definition "$work/message.json" --projection rows \
  --path "$rollout" --repo $'/srv/caf\xe9' --param needle=failure --format json 2>&1); then
  echo "observation accepted a selection that cannot be rendered as UTF-8" >&2
  exit 1
fi
jq -e '.code == "ObservationSelectionNotUtf8"' <<<"$not_utf8" >/dev/null

{
  head -n 1 "$rollout"
  printf '%s\n' '{"timestamp":"2026-07-26T10:00:05Z","type":"event_msg","payload":{"type":"agent_message","message":"dated marker"}}'
  printf '%s\n' '{"type":"event_msg","payload":{"type":"agent_message","message":"undated marker"}}'
} >"$work/nulls.jsonl"
jq -n '{schema:"seq-observation-definition/v1", id:"example/null-ranking",
  requires:{abi:"seq-observation-abi/v1", operators:["derive","project","scan","top-k"]},
  parameters:{}, selectors:["path"], inputs:[],
  relations:[{name:"messages", fields:["text","timestamp"]}],
  pipeline:[{op:"scan", relation:"messages", as:"source"},
    {op:"derive", input:"source", as:"derived", fields:[{name:"label", type:"string",
      nullable:false, expr:{op:"concat", args:[{field:"text"}, "!"]}}]},
    {op:"top-k", input:"derived", as:"ranked",
      by:[{field:"timestamp", direction:"desc", nulls:"last"}], limit:1},
    {op:"project", input:"ranked", as:"rows", fields:["text","timestamp"]}],
  projections:{rows:{relation:"rows", schema:"example-null-ranking/v1",
    fields:["text","timestamp"], renderers:["json"]}},
  bounds:{max_rows:8, max_output_bytes:4096, max_fold_states:1}}' >"$work/null-top-k.json"
jq '.requires.operators = ["derive","limit","project","scan","sort"] |
  .pipeline[2] = {op:"sort", input:"derived", as:"sorted",
    by:[{field:"timestamp", direction:"desc", nulls:"last"}]} |
  .pipeline |= .[0:3] + [{op:"limit", input:"sorted", as:"ranked", limit:1}] + .[3:]' \
  "$work/null-top-k.json" >"$work/null-sort-limit.json"
for shape in null-top-k null-sort-limit; do
  ranked=$("$binary" observe --definition "$work/$shape.json" --projection rows \
    --path "$work/nulls.jsonl" --format json)
  jq -e '.data.rows == [{"text":"dated marker","timestamp":"2026-07-26T10:00:05+00:00"}]' \
    <<<"$ranked" >/dev/null
done
jq -e '.strategy.kind == "bounded-native-prefix"' <<<"$("$binary" explain \
  --definition "$work/null-top-k.json" --projection rows --format json)" >/dev/null
jq -e '.strategy.kind == "materialized-graph"' <<<"$("$binary" explain \
  --definition "$work/null-sort-limit.json" --projection rows --format json)" >/dev/null

windowed="$work/windowed"
mkdir -p "$windowed/sessions/2026/07/26" "$windowed/sessions/2026/08/02" \
  "$windowed/archived_sessions"
jq -c 'if .type == "session_meta" then .payload.id = "fixture-live" else . end' "$rollout" \
  >"$windowed/sessions/2026/07/26/rollout-2026-07-26T10-00-00-live.jsonl"
sed 's/2026-07-26/2026-08-02/g; s/fixture-session/fixture-recent/' "$rollout" \
  >"$windowed/sessions/2026/08/02/rollout-2026-08-02T10-00-00-recent.jsonl"
cp apps/seq/testdata/rollout.jsonl.zst \
  "$windowed/archived_sessions/rollout-2026-07-26T10-00-00-archived.jsonl.zst"
touch -t 202607270000 "$windowed/sessions/2026/07/26/rollout-2026-07-26T10-00-00-live.jsonl" \
  "$windowed/archived_sessions/rollout-2026-07-26T10-00-00-archived.jsonl.zst"
for case in "--since 2026-08-01T00:00:00Z 1 1" "--until 2026-07-20T00:00:00Z 0 0" \
  "--until 2026-07-27T00:00:00Z 2 2"; do
  read -r selector instant files rows <<<"$case"
  windowed_result=$(CODEX_HOME="$windowed" "$binary" observe --definition "$work/message.json" \
    --projection rows "$selector" "$instant" --param needle=failure --format json)
  jq -e --argjson files "$files" --argjson rows "$rows" '.corpus.files == $files and
    .stats.files_opened == $files and (.data.rows | length) == $rows' \
    <<<"$windowed_result" >/dev/null
done

mkdir -p "$work/selected-root" "$work/selected-home/sessions"
cp "$rollout" "$work/selected-root/a.jsonl"
sed 's/2026-07-26/2026-07-28/g; s/fixture-session/fixture-later/' "$rollout" \
  >"$work/selected-root/b.jsonl"
cp "$work/selected-root/a.jsonl" "$work/selected-root/b.jsonl" "$work/selected-home/sessions/"
jq '.selectors = ["path","root","session-id","since","until"] |
  .relations = [{name:"messages", fields:["session_id","text","timestamp"]}] |
  .pipeline[2].limit = 8 | .pipeline[3].fields = ["session_id","text"] |
  .projections.rows.fields = ["session_id","text"]' \
  "$work/null-top-k.json" >"$work/selected-top-k.json"
jq '.selectors = ["path","root","session-id","since","until"] |
  .relations = [{name:"messages", fields:["session_id","text","timestamp"]}] |
  .pipeline[3].limit = 8 | .pipeline[4].fields = ["session_id","text"] |
  .projections.rows.fields = ["session_id","text"]' \
  "$work/null-sort-limit.json" >"$work/selected-sort-limit.json"
for case in "fixture-session|--root|$work/selected-root|--session-id|fixture-session" \
  "fixture-later|--root|$work/selected-root|--since|2026-07-27T00:00:00Z" \
  "fixture-session|--path|$work/selected-home/sessions/a.jsonl"; do
  IFS='|' read -r -a parts <<<"$case"
  shape_results=()
  for shape in selected-top-k selected-sort-limit; do
    shape_results+=("$(CODEX_HOME="$work/selected-home" "$binary" observe \
      --definition "$work/$shape.json" --projection rows "${parts[@]:1}" --format json)")
  done
  jq -e -s --arg session "${parts[0]}" '
    ([.[0].data.rows[].session_id] | unique) == [$session] and
    .[0].data == .[1].data and .[0].corpus.files == .[1].corpus.files and
    .[0].selection == .[1].selection' <<<"${shape_results[0]}${shape_results[1]}" >/dev/null
done

long_text=$(printf 'x%.0s' $(seq 1 3000))
{
  head -n 1 "$rollout"
  jq -cn --arg text "$long_text" \
    '{timestamp:"2026-07-26T10:00:05Z",type:"event_msg",payload:{type:"agent_message",message:$text}}'
} >"$work/wide.jsonl"
jq '.pipeline[1].fields = [
    {name:"first", type:"string", nullable:false,
      expr:{op:"concat", args:[{field:"text"}, "!"]}},
    {name:"second", type:"string", nullable:false,
      expr:{op:"concat", args:[{field:"text"}, "?"]}}] |
  .pipeline[3].fields = ["timestamp"] | .projections.rows.fields = ["timestamp"]' \
  "$work/null-top-k.json" >"$work/wide-top-k.json"
if wide=$("$binary" observe --definition "$work/wide-top-k.json" --projection rows \
  --path "$work/wide.jsonl" --format json); then
  echo "native derivations exceeded their per-row bound without failing" >&2
  exit 1
fi
jq -e '.code == "ObservationExpressionByteBoundExceeded"' <<<"$wide" >/dev/null

if missing_source=$("$binary" turns --path "$work/"$'missing-caf\xe9.jsonl' --format json); then
  echo "a missing non-UTF-8 source path did not fail" >&2
  exit 1
fi
jq -e '.code == "FileNotFound"' <<<"$missing_source" >/dev/null

pruned="$work/pruned-root"
mkdir -p "$pruned"
wanted_id=019f9cf9-37b3-7692-9bd6-f479dc16e385
other_id=019fa6a7-2fe4-7d32-beba-280ecf4e9ff6
jq -c --arg id "$wanted_id" 'if .type == "session_meta" then .payload.id = $id else . end' \
  "$rollout" >"$pruned/rollout-2026-07-26T10-00-00-$wanted_id.jsonl"
printf '%s\n' 'not zstd' >"$pruned/rollout-2026-07-27T10-00-00-$other_id.jsonl.zst"
exact_session=$("$binary" observe --definition "$work/message.json" --projection rows \
  --root "$pruned" --session-id "$wanted_id" --param needle=failure --format json)
jq -e '.corpus.files == 1 and .stats.files_opened == 1 and (.data.rows | length) == 1' \
  <<<"$exact_session" >/dev/null

for shape in null-top-k null-sort-limit; do
  jq '.parameters = {limit: {type: "integer", required: true}} |
    (.pipeline[] | select(.op == "top-k" or .op == "limit") | .limit) = "limit"' \
    "$work/$shape.json" >"$work/$shape-param.json"
  for bad in 0 9; do
    if limited=$("$binary" observe --definition "$work/$shape-param.json" --projection rows \
      --path "$work/nulls.jsonl" --param "limit=$bad" --format json); then
      echo "$shape accepted an out-of-range limit parameter" >&2
      exit 1
    fi
    jq -e '.code == "InvalidObservationLimit"' <<<"$limited" >/dev/null
  done
  limited=$("$binary" observe --definition "$work/$shape-param.json" --projection rows \
    --path "$work/nulls.jsonl" --param limit=1 --format json)
  jq -e '.data.rows == [{"text":"dated marker","timestamp":"2026-07-26T10:00:05+00:00"}]' \
    <<<"$limited" >/dev/null
done

control_definition=apps/seq/src/v1/fixtures/lineage-control-parent.json
control_plan=$("$binary" explain --definition "$control_definition" --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$control_plan" >/dev/null
control_rows=$("$binary" observe --definition "$control_definition" --projection rows \
  --root "$work/aborted-root" --format json)
jq -e '(.data.rows | length) == 1' <<<"$control_rows" >/dev/null

lineage_home="$work/lineage-home"
mkdir -p "$lineage_home/sessions"
cp "$rollout" "$lineage_home/sessions/one.jsonl"
: >"$lineage_home/sessions/aborted.jsonl"
for scoped_source in "$lineage_definition" "$extra_scan_definition" "$control_definition"; do
  scoped_definition="$work/scoped-$(basename "$scoped_source")"
  jq '.selectors = ["path", "root", "session-id"]' "$scoped_source" >"$scoped_definition"
  for scoped_flag in --session-id --path; do
    scoped_value=fixture-session
    [ "$scoped_flag" = --path ] && scoped_value="$lineage_home/sessions/one.jsonl"
    if scoped_result=$(CODEX_HOME="$lineage_home" "$binary" observe \
      --definition "$scoped_definition" --projection rows "$scoped_flag" "$scoped_value" \
      --format json); then
      if [ "$scoped_source" != "$lineage_definition" ]; then
        echo "a lineage fallback widened a scoped selection" >&2
        exit 1
      fi
      jq -e '.corpus.files == 1 and (.data.rows | length) == 1' <<<"$scoped_result" >/dev/null
    else
      [ "$scoped_source" != "$lineage_definition" ]
      jq -e '.code == "ObservationStreamingLineageShapeUnsupported"' <<<"$scoped_result" >/dev/null
    fi
  done
done

jq '.parameters = {limit: {type: "integer", required: false}} |
  (.pipeline[] | select(.op == "limit") | .limit) = "limit"' \
  "$work/null-sort-limit.json" >"$work/optional-limit.json"
if optional_limit=$("$binary" observe --definition "$work/optional-limit.json" --projection rows \
  --path "$work/nulls.jsonl" --format json); then
  echo "an unbound optional limit parameter did not fail" >&2
  exit 1
fi
jq -e '.code == "MissingObservationParameter"' <<<"$optional_limit" >/dev/null

jq '.parameters = {needle: {type: "string", required: false}} | .selectors = ["path", "since"] |
  .pipeline |= (.[0:2] + [{op: "filter", input: "derived", as: "needled",
    where: [{field: "text", op: "contains", param: "needle"}]}] + .[2:]) |
  .pipeline[3].input = "needled" | .requires.operators += ["filter"]' \
  "$work/null-sort-limit.json" >"$work/optional-operand.json"
if optional_operand=$("$binary" observe --definition "$work/optional-operand.json" \
  --projection rows --path "$work/nulls.jsonl" --since 2030-01-01T00:00:00Z --format json); then
  echo "an unbound optional operand passed on an empty filter input" >&2
  exit 1
fi
jq -e '.code == "MissingObservationParameter"' <<<"$optional_operand" >/dev/null

renamed_plan=$("$binary" explain --definition apps/seq/src/v1/fixtures/lineage-renamed-parent.json \
  --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$renamed_plan" >/dev/null
stream_plan=$("$binary" explain --definition "$lineage_definition" --projection rows --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$stream_plan" >/dev/null

if missing_lineage=$(CODEX_HOME="$lineage_home" "$binary" observe \
  --definition "$work/scoped-$(basename "$lineage_definition")" --projection rows \
  --session-id missing-session --format json); then
  echo "streaming lineage accepted an unmatched session id" >&2
  exit 1
fi
jq -e '.code == "SessionNotFound"' <<<"$missing_lineage" >/dev/null

mkdir -p "$work/empty-home/sessions"
jq '.parameters = {role: {type: "string", required: false}} |
  (.pipeline[] | select(.as == "assistant_rows") | .where[0]) |= (del(.value) | .param = "role")' \
  "$lineage_definition" >"$work/optional-role-lineage.json"
if optional_role=$(CODEX_HOME="$work/empty-home" "$binary" observe \
  --definition "$work/optional-role-lineage.json" --projection rows --format json); then
  echo "streaming lineage accepted an unbound optional operand on an empty root" >&2
  exit 1
fi
jq -e '.code == "MissingObservationParameter"' <<<"$optional_role" >/dev/null

{
  head -n 1 "$rollout"
  printf '%s\n' '{"timestamp":"2026-07-26T10:00:05Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-settings","service_tier":"flex"}}}'
} >"$work/settings.jsonl"
jq '.relations = [{name: "sessions", fields: ["session_id", "model", "service_tier", "start_time"]}] |
  .pipeline[0].relation = "sessions" |
  .pipeline[1].fields = [{name: "label", type: "string", nullable: true,
    expr: {field: "session_id"}}] |
  (.pipeline[] | select(.op == "top-k" or .op == "sort") | .by) =
    [{field: "start_time", direction: "desc", nulls: "last"}] |
  .pipeline[-1].fields = ["model", "service_tier"] |
  .projections.rows.fields = ["model", "service_tier"]' \
  "$work/null-top-k.json" >"$work/settings-top-k.json"
jq '.relations = [{name: "sessions", fields: ["session_id", "model", "service_tier", "start_time"]}] |
  .pipeline[0].relation = "sessions" |
  .pipeline[1].fields = [{name: "label", type: "string", nullable: true,
    expr: {field: "session_id"}}] |
  (.pipeline[] | select(.op == "top-k" or .op == "sort") | .by) =
    [{field: "start_time", direction: "desc", nulls: "last"}] |
  .pipeline[-1].fields = ["model", "service_tier"] |
  .projections.rows.fields = ["model", "service_tier"]' \
  "$work/null-sort-limit.json" >"$work/settings-sort-limit.json"
for shape in settings-top-k settings-sort-limit; do
  settings_rows=$("$binary" observe --definition "$work/$shape.json" --projection rows \
    --path "$work/settings.jsonl" --format json)
  jq -e '.data.rows == [{"model":"gpt-settings","service_tier":"flex"}]' \
    <<<"$settings_rows" >/dev/null
done

model_definition=apps/seq/src/v1/fixtures/lineage-session-model.json
model_plan=$("$binary" explain --definition "$model_definition" --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$model_plan" >/dev/null
model_rows=$("$binary" observe --definition "$model_definition" --projection rows \
  --root "$work/aborted-root" --format json)
jq -e '.data.rows == [{"session_id":"fixture-session","model":"gpt-test"}]' \
  <<<"$model_rows" >/dev/null

token_definition=apps/seq/src/v1/fixtures/lineage-token-filter.json
token_plan=$("$binary" explain --definition "$token_definition" --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$token_plan" >/dev/null
mkdir -p "$work/fork-root"
cp "$rollout" "$work/fork-root/parent.jsonl"
jq -c 'if .type == "session_meta" then
  .payload.id = "fixture-child" | .payload.forked_from_id = "fixture-session" else . end' \
  "$rollout" >"$work/fork-root/child.jsonl"
jq '(.pipeline[] | select(.op == "join") | .on.keys) = [{left: "role", right: "role"}]' \
  "$token_definition" >"$work/token-role.json"
token_rows=$("$binary" observe --definition "$work/token-role.json" --projection rows \
  --root "$work/fork-root" --format json)
jq -e '[.data.rows[].session_id] == ["fixture-session"]' <<<"$token_rows" >/dev/null

jq '.requires.operators += ["limit"] |
  .pipeline = [.pipeline[0], {op:"limit", input:"session_rows", as:"first_session", limit:1}] +
    .pipeline[1:] |
  (.pipeline[] | select(.op == "join") | .inputs[2]) = "first_session" |
  (.pipeline[] | select(.op == "join") | .on.keys) = [{left: "role", right: "role"}]' \
  "$lineage_definition" >"$work/limited-lineage.json"
limited_plan=$("$binary" explain --definition "$work/limited-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$limited_plan" >/dev/null
limited_rows=$("$binary" observe --definition "$work/limited-lineage.json" --projection rows \
  --root "$work/fork-root" --format json)
jq -e '[.data.rows[].session_id] == ["fixture-session"]' <<<"$limited_rows" >/dev/null

jq '(.pipeline[] | select(.op == "join") | .on.lineage.right) = "role"' \
  "$lineage_definition" >"$work/role-lineage.json"
role_plan=$("$binary" explain --definition "$work/role-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$role_plan" >/dev/null

mkdir -p "$work/duplicate-root"
cp "$rollout" "$work/duplicate-root/a.jsonl"
cp "$rollout" "$work/duplicate-root/b.jsonl"
if duplicate=$("$binary" observe --definition "$lineage_definition" --projection rows \
  --root "$work/duplicate-root" --format json); then
  echo "streaming lineage accepted a duplicated session id" >&2
  exit 1
fi
jq -e '.code == "DuplicateObservationLineageNode"' <<<"$duplicate" >/dev/null

legacy_rollout=libs/trace_core/testdata/old_2025_08_root_meta.jsonl
for shape in top-k sort-limit; do
  jq '.relations = [{name: "sessions",
      fields: ["session_id", "turn_count", "status_reason", "start_time"]}] |
    .pipeline[0].relation = "sessions" |
    .pipeline[1].fields = [{name: "label", type: "string", nullable: true,
      expr: {field: "session_id"}}] |
    (.pipeline[] | select(.op == "top-k" or .op == "sort") | .by) =
      [{field: "start_time", direction: "desc", nulls: "last"}] |
    .pipeline[-1].fields = ["session_id", "turn_count", "status_reason"] |
    .projections.rows.fields = ["session_id", "turn_count", "status_reason"]' \
    "$work/null-$shape.json" >"$work/turns-$shape.json"
  turns_plan=$("$binary" explain --definition "$work/turns-$shape.json" --projection rows \
    --format json)
  jq -e '.strategy.kind == "materialized-graph"' <<<"$turns_plan" >/dev/null
  turns_rows=$("$binary" observe --definition "$work/turns-$shape.json" --projection rows \
    --path "$legacy_rollout" --format json)
  jq -e '.data.rows == [{"session_id":"old-session","turn_count":2,
    "status_reason":"synthetic_message_boundary"}]' <<<"$turns_rows" >/dev/null
done

jq '(.pipeline[] | select(.op == "join") | .on.keys) = [{left: "source_event_id", right: "role"}]' \
  "$lineage_definition" >"$work/asymmetric-lineage.json"
asymmetric_plan=$("$binary" explain --definition "$work/asymmetric-lineage.json" \
  --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$asymmetric_plan" >/dev/null

mkdir -p "$work/two-roots"
cp "$rollout" "$work/two-roots/one.jsonl"
jq -c 'if .type == "session_meta" then .payload.id = "fixture-two" else . end' \
  "$rollout" >"$work/two-roots/two.jsonl"
jq '(.pipeline[] | select(.op == "join") | .on.kind) = "semi"' \
  "$lineage_definition" >"$work/semi-lineage.json"
jq '.requires.operators += ["sort"] |
  .pipeline = .pipeline[0:3] + [{op: "sort", input: "assistant_rows", as: "sorted_rows",
    by: [{field: "source_event_id", direction: "asc"}]}] + .pipeline[3:] |
  (.pipeline[] | select(.op == "join") | .inputs) = ["sorted_rows", "sorted_rows", "session_rows"]' \
  "$lineage_definition" >"$work/sorted-lineage.json"
jq '.requires.operators += ["distinct"] |
  .pipeline = .pipeline[0:3] + [{op: "distinct", input: "assistant_rows", as: "first_roles",
    keys: ["role"]}] + .pipeline[3:] |
  (.pipeline[] | select(.op == "join") | .inputs) = ["first_roles", "first_roles", "session_rows"] |
  (.pipeline[] | select(.op == "join") | .on.keys) = [{left: "role", right: "role"}]' \
  "$lineage_definition" >"$work/role-distinct-lineage.json"
for shape in semi-lineage sorted-lineage role-distinct-lineage; do
  shape_plan=$("$binary" explain --definition "$work/$shape.json" --projection rows --format json)
  jq -e '.strategy.kind == "materialized-graph"' <<<"$shape_plan" >/dev/null
  "$binary" observe --definition "$work/$shape.json" --projection rows \
    --root "$work/two-roots" --format json >"$work/$shape-rows.json"
done
jq -e '[.data.rows[].session_id] == ["fixture-session"]' \
  "$work/role-distinct-lineage-rows.json" >/dev/null
jq '(.pipeline[] | select(.op == "distinct") | .keys) = ["session_id", "role"]' \
  "$work/role-distinct-lineage.json" >"$work/session-distinct-lineage.json"
session_distinct_plan=$("$binary" explain --definition "$work/session-distinct-lineage.json" \
  --projection rows --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$session_distinct_plan" >/dev/null
jq '(.pipeline[] | select(.op == "join") | .fields) |= [.[0], .[2], .[1]] |
  .projections.rows.fields = ["session_id", "source_event_id", "role"]' \
  "$lineage_definition" >"$work/reordered-lineage.json"
reordered_plan=$("$binary" explain --definition "$work/reordered-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$reordered_plan" >/dev/null
jq '(.pipeline[] | select(.op == "join") | .fields) |= [.[0], .[2]] |
  .projections.rows.fields = ["session_id", "source_event_id"]' \
  "$lineage_definition" >"$work/subset-lineage.json"
for shape in reordered-lineage subset-lineage; do
  jq '.relations[0].fields += ["model"]' "$work/$shape.json" >"$work/$shape-materialized.json"
  streamed=$("$binary" observe --definition "$work/$shape.json" --projection rows \
    --root "$work/fork-root" --format json)
  materialized=$("$binary" observe --definition "$work/$shape-materialized.json" \
    --projection rows --root "$work/fork-root" --format json)
  printf '%s\n' "$streamed" "$materialized" | jq -se '
    .[0].data.rows == .[1].data.rows and (.[0].data.rows | length) == 2' >/dev/null
done

post_limit_plan=$("$binary" explain --definition "$work/lineage-limit.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$post_limit_plan" >/dev/null
post_limit_rows=$("$binary" observe --definition "$work/lineage-limit.json" --projection rows \
  --root "$work/fork-root" --format json)
jq -e '[.data.rows[].session_id] == ["fixture-child"]' <<<"$post_limit_rows" >/dev/null
ordered_rows=$("$binary" observe --definition "$lineage_definition" --projection rows \
  --root "$work/fork-root" --format json)
jq -e '[.data.rows[].session_id] == ["fixture-child", "fixture-session"]' \
  <<<"$ordered_rows" >/dev/null

jq '.requires.operators += ["ordered-fold"] |
  .pipeline = .pipeline[0:3] + [{op: "ordered-fold", input: "assistant_rows", as: "folded_rows",
    keys: ["session_id"], order_by: [{field: "source_event_id", direction: "asc"}],
    state: [], transitions: [],
    emit: [{name: "session_id", type: "string", nullable: false, expr: {field: "session_id"}},
      {name: "role", type: "string", nullable: true, expr: {field: "role"}},
      {name: "source_event_id", type: "string", nullable: false,
        expr: {field: "source_event_id"}}]}] + .pipeline[3:] |
  (.pipeline[] | select(.op == "join") | .inputs) = ["folded_rows", "folded_rows", "session_rows"]' \
  "$lineage_definition" >"$work/folded-lineage.json"
folded_plan=$("$binary" explain --definition "$work/folded-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$folded_plan" >/dev/null
"$binary" observe --definition "$work/folded-lineage.json" --projection rows \
  --root "$work/two-roots" --format json >/dev/null
reject_join() {
  local shape=$1 code=$2 failure
  if failure=$("$binary" explain --definition "$work/$shape.json" --projection rows \
    --format json); then
    echo "malformed join was planned: $shape" >&2
    exit 1
  fi
  jq -e --arg code "$code" '.code == $code' <<<"$failure" >/dev/null
  if failure=$("$binary" observe --definition "$work/$shape.json" --projection rows \
    --root "$work/two-roots" --format json); then
    echo "malformed join was observed: $shape" >&2
    exit 1
  fi
  jq -e --arg code "$code" '.code == $code' <<<"$failure" >/dev/null
}
malformed_join() {
  jq "(.pipeline[] | select(.op == \"join\")) |= ($2)" "$lineage_definition" >"$work/$1.json"
  reject_join "$1" "$3"
}
malformed_join flagged-lineage '.on.left_true = "missing_flag"' UnknownObservationJoinField
malformed_join string-flag-lineage '.on.left_true = "role"' ObservationJoinFlagRequiresBoolean
malformed_join keyless-lineage '.on.keys = []' ObservationJoinRequiresEqualityKey
malformed_join unknown-key-lineage '.on.keys = [{left: "missing_key", right: "missing_key"}]' \
  UnknownObservationJoinField
malformed_join unknown-op-lineage '.on.keys += [{left: "role", right: "role", op: "ne"}]' \
  ObservationJoinOperatorUnsupported
malformed_join unknown-kind-lineage '.on.kind = "outer"' ObservationJoinKindUnsupported
malformed_join unknown-node-lineage '.on.lineage.node = "missing_node"' \
  UnknownObservationLineageField
jq '(.relations[] | select(.name == "sessions") | .fields) = ["session_id"]' \
  "$lineage_definition" >"$work/parentless-lineage.json"
reject_join parentless-lineage UnknownObservationLineageField
jq '.relations[0].fields += ["model"]' "$lineage_definition" >"$work/materialized-lineage.json"
materialized_rows=$("$binary" observe --definition "$work/materialized-lineage.json" \
  --projection rows --root "$work/fork-root" --format json)
printf '%s\n' "$ordered_rows" "$materialized_rows" | jq -se '
  .[0].corpus.digest == .[1].corpus.digest and
  ([.[0].data.rows[].session_id] == [.[1].data.rows[].session_id])' >/dev/null
jq '.requires.operators += ["derive"] |
  .pipeline = .pipeline[0:3] + [{op: "derive", input: "assistant_rows", as: "literal_rows",
    preserve_input: false,
    fields: [{name: "session_id", type: "string", nullable: false, expr: "fixed"},
      {name: "role", type: "string", nullable: true, expr: {field: "role"}},
      {name: "source_event_id", type: "string", nullable: false,
        expr: {field: "source_event_id"}}]}] + .pipeline[3:] |
  (.pipeline[] | select(.op == "join") | .inputs) = ["literal_rows", "literal_rows", "session_rows"]' \
  "$lineage_definition" >"$work/literal-lineage.json"
literal_plan=$("$binary" explain --definition "$work/literal-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$literal_plan" >/dev/null
malformed_join nulls-text-lineage '.on.keys[0].nulls_equal = "yes"' ExpectedBoolean
malformed_join bool-flag-lineage '.on.left_true = true' ExpectedString
malformed_join unknown-output-lineage '.fields[1].field = "missing_field"' \
  UnknownObservationJoinField
malformed_join far-source-lineage '.fields[1].source = 2' ObservationJoinSourceUnsupported
malformed_join right-output-lineage '.fields[1].source = 1' ObservationMembershipJoinProjectsRight

jq '(.pipeline[] | select(.op == "join") | .inputs) = ["assistant_rows", "session_rows"]' \
  "$lineage_definition" >"$work/two-input-lineage.json"
second_lineage='.pipeline += [{op: "join", inputs: $inputs, as: "second_rows",
    on: {kind: "anti", keys: [{left: "source_event_id", right: "source_event_id"}],
      lineage: {left: "session_id", right: "session_id", node: "session_id",
        parent: "parent_session_id"}},
    fields: [{source: 0, field: "session_id", name: "session_id", type: "string",
      nullable: false}]}] |
  .projections.rows = {relation: "second_rows", schema: "example/second/v1",
    fields: ["session_id"], renderers: ["json"]}'
jq --argjson inputs '["owned_rows", "owned_rows"]' \
  '(.pipeline[] | select(.op == "join") | .on.kind) = "semi" | '"$second_lineage" \
  "$lineage_definition" >"$work/second-lineage.json"
jq --argjson inputs '["owned_rows", "session_rows"]' "$second_lineage" \
  "$lineage_definition" >"$work/streamed-second-lineage.json"
jq --argjson inputs '["owned_rows", "owned_rows", "session_rows", "session_rows"]' \
  "$second_lineage" "$lineage_definition" >"$work/four-input-lineage.json"
for shape in two-input-lineage second-lineage streamed-second-lineage four-input-lineage; do
  reject_join "$shape" ObservationLineageInputMissing
done
jq '.pipeline = .pipeline[0:3] + [{op: "join", inputs: ["assistant_rows", "assistant_rows"],
    as: "paired_rows",
    on: {kind: "inner", keys: [{left: "source_event_id", right: "source_event_id"},
      {left: "session_id", right: "session_id"}]},
    fields: [{source: 1, field: "session_id", name: "session_id", type: "string", nullable: true},
      {source: 0, field: "role", name: "role", type: "string", nullable: true},
      {source: 0, field: "source_event_id", name: "source_event_id", type: "string",
        nullable: false}]}] + .pipeline[3:] |
  (.pipeline[] | select(.as == "owned_rows") | .inputs) = ["paired_rows", "paired_rows", "session_rows"]' \
  "$lineage_definition" >"$work/right-session-lineage.json"
right_session_plan=$("$binary" explain --definition "$work/right-session-lineage.json" \
  --projection rows --format json)
jq -e '.strategy.kind == "materialized-graph"' <<<"$right_session_plan" >/dev/null
jq '(.pipeline[] | select(.as == "paired_rows") | .on.keys[0].right) = "missing_key"' \
  "$work/right-session-lineage.json" >"$work/local-key-lineage.json"
reject_join local-key-lineage UnknownObservationJoinField

malformed_join misspelled-lineage '.on.linage = .on.lineage | del(.on.lineage)' \
  UnknownObservationJoinOption
malformed_join unknown-key-option '.on.keys[0].nulls = true' UnknownObservationJoinOption
malformed_join unknown-field-option '.fields[0].nulable = true' UnknownObservationJoinOption
malformed_join ordering-nulls-lineage \
  '.on.keys += [{left: "role", right: "role", op: "lt", nulls_equal: true}]' \
  ObservationJoinNullsEqualRequiresEquality

mkdir -p "$work/legacy-root"
jq -c 'select(.type == "session_meta") | .payload |= del(.cwd)' "$rollout" >"$work/legacy-root/legacy.jsonl"
printf '%s\n' '{"type":"turn_context","timestamp":"2026-07-26T10:00:01Z","payload":{"cwd":"/other"}}' \
  >>"$work/legacy-root/legacy.jsonl"
jq -c 'select(.type != "session_meta")' "$rollout" >>"$work/legacy-root/legacy.jsonl"
legacy_rows=$("$binary" observe --definition "$lineage_definition" --projection rows \
  --root "$work/legacy-root" --repo /repo --format json)
jq -e '.corpus.files == 1 and (.data.rows | length) == 1' <<<"$legacy_rows" >/dev/null

mkdir -p "$work/depth-root"
cp "$rollout" "$work/depth-root/root.jsonl"
jq -c 'if .type == "session_meta" then
  .payload.id = "fixture-child" | .payload.forked_from_id = "fixture-session" else . end' \
  "$rollout" >"$work/depth-root/child.jsonl"
jq -c 'if .type == "session_meta" then
  .payload.id = "fixture-grandchild" | .payload.forked_from_id = "fixture-child" else . end' \
  "$rollout" >"$work/depth-root/grandchild.jsonl"
jq '.bounds.max_graph_depth = 2' "$lineage_definition" >"$work/depth-stream.json"
jq '.bounds.max_graph_depth = 2 | .relations[0].fields += ["model"]' "$lineage_definition" \
  >"$work/depth-materialized.json"
depth_stream=$("$binary" observe --definition "$work/depth-stream.json" --projection rows \
  --root "$work/depth-root" --format json)
depth_materialized=$("$binary" observe --definition "$work/depth-materialized.json" \
  --projection rows --root "$work/depth-root" --format json)
printf '%s\n' "$depth_stream" "$depth_materialized" | jq -se '
  (.[0].data.rows | length) == 3 and
  ([.[0].data.rows[].session_id] == [.[1].data.rows[].session_id])' >/dev/null
mkdir -p "$work/self-root"
jq -c 'if .type == "session_meta" then .payload.forked_from_id = "fixture-session" else . end' \
  "$rollout" >"$work/self-root/self.jsonl"
for shape in depth-stream depth-materialized; do
  if self_cycle=$("$binary" observe --definition "$work/$shape.json" --projection rows \
    --root "$work/self-root" --format json); then
    echo "self-parented lineage was accepted: $shape" >&2
    exit 1
  fi
  jq -e '.code == "ObservationGraphCycle"' <<<"$self_cycle" >/dev/null
done

jq 'def stage(i; o): {op: "filter", input: i, as: o,
    where: [{field: "role", op: "exact", value: "assistant"}]};
  .pipeline = [.pipeline[0], .pipeline[1],
    stage("message_rows"; "a1"), stage("a1"; "a2"), stage("a2"; "a3"), stage("a3"; "a4"),
    stage("a4"; "b1"), stage("b1"; "b2"), stage("b2"; "b3"), stage("b3"; "b4"),
    {op: "join", inputs: ["a4", "b4"], as: "paired_rows",
      on: {kind: "inner", keys: [{left: "session_id", right: "session_id"},
        {left: "source_event_id", right: "source_event_id"}]},
      fields: [{source: 0, field: "session_id", name: "session_id", type: "string",
          nullable: false},
        {source: 0, field: "role", name: "role", type: "string", nullable: true},
        {source: 0, field: "source_event_id", name: "source_event_id", type: "string",
          nullable: false}]},
    ((.pipeline[] | select(.op == "join")) | .inputs = ["paired_rows", "paired_rows",
      "session_rows"])]' "$lineage_definition" >"$work/dag-lineage.json"
dag_plan=$("$binary" explain --definition "$work/dag-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$dag_plan" >/dev/null
"$binary" observe --definition "$work/dag-lineage.json" --projection rows \
  --root "$work/two-roots" --format json >/dev/null

mkdir -p "$work/failed-spawn-root"
jq -c 'if .type == "session_meta" then
  .payload.id = "fork-child" | .payload.forked_from_id = "fixture-session" else . end' \
  "$rollout" >"$work/failed-spawn-root/fork.jsonl"
printf '%s\n' '{"type":"event_msg","payload":{"type":"collab_agent_spawn_end","call_id":"failed","new_thread_id":null,"status":"not_found"}}' \
  >>"$work/failed-spawn-root/fork.jsonl"
"$binary" sessions --root "$work/failed-spawn-root" --format json >/dev/null

mkdir -p "$work/session-order-root"
jq -c 'if .type == "session_meta" then .payload.id = "zeta" else . end' "$rollout" \
  >"$work/session-order-root/a.jsonl"
jq -c 'if .type == "session_meta" then .payload.id = "alpha" else . end' "$rollout" \
  >"$work/session-order-root/b.jsonl"
for direction in asc desc; do
  jq --arg direction "$direction" '.requires.operators += ["ordered-fold"] |
    .pipeline = .pipeline[0:3] + [{op: "ordered-fold", input: "assistant_rows",
      as: "folded_rows", keys: ["session_id"],
      order_by: [{field: "session_id", direction: $direction},
        {field: "source_event_id", direction: "asc"}],
      state: [], transitions: [],
      emit: [{name: "session_id", type: "string", nullable: false,
          expr: {field: "session_id"}},
        {name: "role", type: "string", nullable: true, expr: {field: "role"}},
        {name: "source_event_id", type: "string", nullable: false,
          expr: {field: "source_event_id"}}]}] + .pipeline[3:] |
    (.pipeline[] | select(.op == "join") | .inputs) = ["folded_rows", "folded_rows",
      "session_rows"]' "$lineage_definition" >"$work/session-fold-$direction.json"
  jq '.relations[0].fields += ["model"]' "$work/session-fold-$direction.json" \
    >"$work/session-fold-$direction-materialized.json"
  fold_plan=$("$binary" explain --definition "$work/session-fold-$direction.json" \
    --projection rows --format json)
  jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$fold_plan" >/dev/null
  fold_stream=$("$binary" observe --definition "$work/session-fold-$direction.json" \
    --projection rows --root "$work/session-order-root" --format json)
  fold_materialized=$("$binary" observe \
    --definition "$work/session-fold-$direction-materialized.json" --projection rows \
    --root "$work/session-order-root" --format json)
  printf '%s\n' "$fold_stream" "$fold_materialized" | jq -se --arg direction "$direction" '
    .[0].corpus.digest == .[1].corpus.digest and .[0].data.rows == .[1].data.rows and
    ([.[0].data.rows[].session_id] ==
      (if $direction == "asc" then ["alpha", "zeta"] else ["zeta", "alpha"] end))' >/dev/null
done

mkdir -p "$work/late-identity-root"
cp "$rollout" "$work/late-identity-root/a.jsonl"
{
  printf '%s\n' '{"type":"turn_context","timestamp":"2026-07-26T09:59:59Z","payload":{"cwd":"/repo"}}'
  cat "$rollout"
} >"$work/late-identity-root/b.jsonl"
jq '.relations[0].fields += ["model"]' "$lineage_definition" >"$work/late-materialized.json"
late_stream=$("$binary" observe --definition "$lineage_definition" --projection rows \
  --root "$work/late-identity-root" --format json)
late_materialized=$("$binary" observe --definition "$work/late-materialized.json" \
  --projection rows --root "$work/late-identity-root" --format json)
"$binary" explain --definition "$work/late-materialized.json" --projection rows --format json |
  jq -e '.strategy.kind == "materialized-graph"' >/dev/null
printf '%s\n' "$late_stream" "$late_materialized" | jq -se '
  .[0].data.rows == .[1].data.rows and
  ([.[0].data.rows[].session_id] == ["fixture-session", null])' >/dev/null

order_session() {
  jq -c --arg id "$3" --arg parent "$4" --arg cwd "$5" '
    if .type == "session_meta" then .payload.id = $id | .payload.cwd = $cwd |
      (if $parent == "" then . else .payload.forked_from_id = $parent end) else . end' \
    "$rollout" >"$1/$2"
}
jq '(.pipeline[] | select(.op == "join") | .on.keys) = [{left: "role", right: "role"}] |
  .bounds.max_graph_depth = 2' "$lineage_definition" >"$work/role-order-lineage.json"
jq '.bounds.max_graph_depth = 2' "$lineage_definition" >"$work/event-order-lineage.json"
for keyed in role event; do
  jq '.relations[0].fields += ["model"]' "$work/$keyed-order-lineage.json" \
    >"$work/$keyed-order-materialized.json"
done
for shape in cycle chain self; do
  for first in child parent; do
    order_root="$work/order-$shape-$first"
    mkdir -p "$order_root"
    child_file=a.jsonl
    parent_file=b.jsonl
    if [ "$first" = parent ]; then
      child_file=b.jsonl
      parent_file=a.jsonl
    fi
    case "$shape" in
      cycle)
        order_session "$order_root" x1.jsonl x1 x2 /other
        order_session "$order_root" x2.jsonl x2 x1 /other
        order_session "$order_root" "$parent_file" p x1 /repo
        ;;
      chain)
        order_session "$order_root" x0.jsonl x0 "" /repo
        order_session "$order_root" x1.jsonl x1 x0 /other
        order_session "$order_root" x2.jsonl x2 x1 /other
        order_session "$order_root" "$parent_file" p x2 /repo
        ;;
      self)
        order_session "$order_root" x1.jsonl x1 x1 /other
        order_session "$order_root" "$parent_file" p x1 /repo
        ;;
    esac
    order_session "$order_root" "$child_file" c p /repo
    for keyed in role event; do
      order_stream=$("$binary" observe --definition "$work/$keyed-order-lineage.json" \
        --projection rows --root "$order_root" --repo /repo --format json)
      order_materialized=$("$binary" observe \
        --definition "$work/$keyed-order-materialized.json" --projection rows \
        --root "$order_root" --repo /repo --format json)
      printf '%s\n' "$order_stream" "$order_materialized" | jq -se --arg keyed "$keyed" '
        .[0].data.rows == .[1].data.rows and
        (([.[1].data.rows[].session_id] | index("c")) == null) == ($keyed == "role")' \
        >/dev/null
    done
  done
done

scope_home="$work/scope-home"
mkdir -p "$scope_home/sessions"
order_session "$scope_home/sessions" s.jsonl s "" /repo
order_session "$scope_home/sessions" q.jsonl q q /other
order_session "$scope_home/sessions" deep0.jsonl d0 "" /repo
order_session "$scope_home/sessions" deep1.jsonl d1 d0 /other
order_session "$scope_home/sessions" deep2.jsonl d2 d1 /other
order_session "$scope_home/sessions" deep3.jsonl d3 d2 /repo
jq '.bounds.max_graph_depth = 2 | .selectors = ["path", "root", "session-id", "repo"]' \
  "$lineage_definition" >"$work/scoped-order-lineage.json"
scoped_rows() {
  CODEX_HOME="$scope_home" "$binary" observe --definition "$work/scoped-order-lineage.json" \
    --projection rows --repo /repo "$@" --format json | jq -c '[.data.rows[].session_id]'
}
[ "$(scoped_rows)" = '["d0","d3","s"]' ]
[ "$(scoped_rows --session-id s)" = '["s"]' ]
[ "$(scoped_rows --path "$scope_home/sessions/s.jsonl")" = '["s"]' ]
[ "$(scoped_rows --session-id d3)" = '["d0","d3"]' ]
[ "$(scoped_rows --path "$scope_home/sessions/deep3.jsonl")" = '["d0","d3"]' ]

jq '(.pipeline[] | select(.op == "join") | .on.keys) = [{left: "role", right: "role"}] |
  .pipeline = [.pipeline[0], {op: "filter", input: "session_rows", as: "child_session",
      where: [{field: "session_id", op: "exact", value: "fixture-child"}]}] + .pipeline[1:] |
  (.pipeline[] | select(.op == "join") | .inputs[2]) = "child_session"' \
  "$lineage_definition" >"$work/filtered-lineage.json"
filtered_plan=$("$binary" explain --definition "$work/filtered-lineage.json" --projection rows \
  --format json)
jq -e '.strategy.kind == "partition-lineage-stream"' <<<"$filtered_plan" >/dev/null
filtered_rows=$("$binary" observe --definition "$work/filtered-lineage.json" --projection rows \
  --root "$work/fork-root" --format json)
jq -e '[.data.rows[].session_id] == ["fixture-session"]' <<<"$filtered_rows" >/dev/null

jq '.relations[0].fields += ["parent_relation"] |
  .pipeline = [.pipeline[0], {op: "filter", input: "session_rows", as: "fork_rows",
      where: [{field: "parent_relation", op: "exact", value: "forked_from_id"}]}] +
    .pipeline[1:] |
  (.pipeline[] | select(.op == "join") | .inputs[2]) = "fork_rows"' \
  "$lineage_definition" >"$work/event-fork-lineage.json"
jq '(.pipeline[] | select(.op == "join") | .on.keys) = [{left: "role", right: "role"}]' \
  "$work/event-fork-lineage.json" >"$work/role-fork-lineage.json"
for keyed in role event; do
  jq '.relations[0].fields += ["model"]' "$work/$keyed-fork-lineage.json" \
    >"$work/$keyed-fork-materialized.json"
  "$binary" explain --definition "$work/$keyed-fork-lineage.json" --projection rows \
    --format json | jq -e '.strategy.kind == "partition-lineage-stream"' >/dev/null
done
for first in child parent; do
  fork_order_root="$work/fork-order-$first"
  mkdir -p "$fork_order_root"
  child_file=a.jsonl
  parent_file=b.jsonl
  if [ "$first" = parent ]; then
    child_file=b.jsonl
    parent_file=a.jsonl
  fi
  order_session "$fork_order_root" "$parent_file" p "" /repo
  order_session "$fork_order_root" "$child_file" c p /repo
  for keyed in role event; do
    fork_stream=$("$binary" observe --definition "$work/$keyed-fork-lineage.json" \
      --projection rows --root "$fork_order_root" --format json)
    fork_materialized=$("$binary" observe \
      --definition "$work/$keyed-fork-materialized.json" --projection rows \
      --root "$fork_order_root" --format json)
    printf '%s\n' "$fork_stream" "$fork_materialized" | jq -se --arg keyed "$keyed" '
      .[0].data.rows == .[1].data.rows and
      (([.[1].data.rows[].session_id] | index("c")) == null) == ($keyed == "role")' \
      >/dev/null
  done
done

parity_root="$work/parser-parity"
mkdir -p "$parity_root"
parity_meta='{"timestamp":"2026-07-26T10:00:00Z","type":"session_meta","payload":{"id":"#"}}'
parity_session() {
  { printf '%s\n' "${parity_meta/\#/$1}"; cat; } >"$parity_root/$1.jsonl"
}
parity_session root-spawn <<'LINES'
{"type":"function_call","name":"spawn_agent","call_id":"c1","arguments":"{}"}
{"type":"function_call_output","call_id":"c1","output":"{\"agent_id\":\"w1\"}"}
LINES
parity_session nested-event <<'LINES'
{"type":"event_msg","payload":{"meta":{"type":"response_item"},"type":"sub_agent_activity","event_id":"e1","agent_thread_id":"w2","agent_path":"/root/w2","kind":"started"}}
LINES
parity_session root-context <<'LINES'
{"timestamp":"2026-07-26T10:00:01Z","type":"turn_context","model":"gpt-root","cwd":"/repo"}
LINES
summary_rows=$("$binary" sessions --root "$parity_root" --format json)
for id in root-spawn nested-event root-context; do
  full_session=$("$binary" session-detail --path "$parity_root/$id.jsonl" --format json)
  printf '%s\n' "$summary_rows" "$full_session" | jq -se --arg id "$id" '
    ([.[0] | .. | objects | select(.session_id? == $id and has("spawned_worker_count"))]
      | first) as $summary |
    .[1].session as $full |
    $summary != null and
    ($summary | {spawned_worker_count, model, cwd}) ==
      ($full | {spawned_worker_count, model, cwd}) and
    (if $id == "root-context" then $full.model == "gpt-root" and $full.cwd == "/repo"
     else $full.spawned_worker_count == 1 end)' >/dev/null
done

depth_root="$work/stage-depth"
mkdir -p "$depth_root"
jq -c 'if .type == "session_meta" then .payload.id = "p0" else . end' "$rollout" \
  >"$depth_root/a.jsonl"
jq -c 'if .type == "session_meta" then .payload.id = "c0" | .payload.forked_from_id = "p0"
  else . end' "$rollout" >"$depth_root/b.jsonl"
for shape in executor seed; do
  jq --arg shape "$shape" '
    def keep(src; dst): {op: "filter", input: src, "as": dst,
      where: [{field: "session_id", op: "ne", value: "none"}]};
    def key: [{left: "session_id", right: "session_id"}];
    def id: [{source: 0, field: "session_id", name: "session_id", type: "string",
      nullable: false}];
    .bounds.max_graph_depth = 5 | .relations = [.relations[0]] |
    .pipeline = [{op: "scan", relation: "sessions", "as": "s"},
        keep("s"; "f1"), keep("f1"; "f2"), keep("f2"; "z")] +
      (if $shape == "executor"
       then [keep("z"; "c"), keep("c"; "b"), keep("b"; "x"), keep("z"; "g")]
       else [keep("z"; "b"), keep("b"; "c"), keep("c"; "g"), keep("z"; "x")] end) +
      [{op: "join", inputs: ["x", "x", "g"], "as": "j", fields: id,
        on: {kind: "anti", keys: key, lineage: {left: "session_id",
          right: "session_id", node: "session_id", parent: "parent_session_id"}}},
       keep("z"; "g2"),
       {op: "join", inputs: ["g2", "j"], "as": "p", fields: id,
        on: {kind: "semi", keys: key}}] |
    .projections = {rows: {relation: "p", schema: "example/stage-depth/v1",
      fields: ["session_id"], renderers: ["json"]}}' "$lineage_definition" \
    >"$work/depth-$shape.json"
  jq '.relations[0].fields += ["model"]' "$work/depth-$shape.json" \
    >"$work/depth-$shape-materialized.json"
  "$binary" explain --definition "$work/depth-$shape.json" --projection rows \
    --format json | jq -e '.strategy.kind == "partition-lineage-stream"' >/dev/null
  depth_stream=$("$binary" observe --definition "$work/depth-$shape.json" \
    --projection rows --root "$depth_root" --format json)
  depth_materialized=$("$binary" observe \
    --definition "$work/depth-$shape-materialized.json" --projection rows \
    --root "$depth_root" --format json)
  printf '%s\n' "$depth_stream" "$depth_materialized" | jq -se '
    .[0].data.rows == .[1].data.rows and (.[0].data.rows | length) == 2' >/dev/null
done

digest_root="$work/digest-order"
mkdir -p "$digest_root"
jq -c 'if .type == "session_meta" then .payload.id = "C" | .payload.forked_from_id = "P"
  else . end' "$rollout" >"$digest_root/a.jsonl"
jq -c 'if .type == "session_meta" then .payload.id = "P" else . end' "$rollout" \
  >"$digest_root/b.jsonl"
jq '.pipeline = [.pipeline[0], {op: "filter", input: "session_rows", "as": "graph_rows",
      where: [{field: "session_id", op: "exact", value: "P"}]}] + .pipeline[1:] |
  (.pipeline[] | select(.op == "join") | .inputs[2]) = "graph_rows"' \
  "$lineage_definition" >"$work/digest-filtered.json"
"$binary" explain --definition "$work/digest-filtered.json" --projection rows \
  --format json | jq -e '.strategy.kind == "partition-lineage-stream"' >/dev/null
digest_plain=$("$binary" observe --definition "$lineage_definition" --projection rows \
  --root "$digest_root" --format json)
digest_filtered=$("$binary" observe --definition "$work/digest-filtered.json" \
  --projection rows --root "$digest_root" --format json)
printf '%s\n' "$digest_plain" "$digest_filtered" | jq -se '
  .[0].corpus.digest == .[1].corpus.digest and
  .[0].context.source_metadata_digest == .[1].context.source_metadata_digest' >/dev/null

expression_home="$work/expression-home"
mkdir -p "$expression_home/sessions"
cp "$rollout" "$expression_home/sessions/one.jsonl"
graph_derive() {
  jq --argjson stages "$2" '.requires.operators += ["derive"] |
    .selectors = ["path", "root", "session-id"] |
    .pipeline = [.pipeline[0]] + $stages + .pipeline[1:] |
    (.pipeline[] | select(.op == "join") | .inputs[2]) = "graph_rows"' \
    "$lineage_definition" | jq "$3" >"$work/$1.json"
}
token_tag='{op: "derive", input: "session_rows", "as": "graph_rows", fields: [{name: "tag",
  type: $type, nullable: true, expr: $expr}]}'
graph_derive token-literal "$(jq -n --arg type string \
  --argjson expr '"token_usage_observation_count"' "[$token_tag]")" \
  '.relations[0].fields += ["token_usage_observation_count"]'
graph_derive token-read "$(jq -n --arg type integer \
  --argjson expr '{"field":"token_usage_observation_count"}' "[$token_tag]")" \
  '.relations[0].fields += ["token_usage_observation_count"]'
graph_derive token-defined '[{"op":"derive","input":"session_rows","as":"defined_rows",
    "fields":[{"name":"token_usage_observation_count","type":"integer","nullable":false,
      "expr":0}]},
  {"op":"filter","input":"defined_rows","as":"graph_rows",
    "where":[{"field":"token_usage_observation_count","op":"eq","value":0}]}]' .
jq '.requires.operators += ["derive"] | .selectors = ["path", "root", "session-id"] |
  .pipeline = .pipeline[0:3] + [{op: "derive", input: "assistant_rows", "as": "copied_rows",
    preserve_input: false,
    fields: [{name: "session_id", type: "string", nullable: false,
        expr: {field: "session_id", note: "copy"}},
      {name: "role", type: "string", nullable: true, expr: {field: "role"}},
      {name: "source_event_id", type: "string", nullable: false,
        expr: {field: "source_event_id"}}]}] + .pipeline[3:] |
  (.pipeline[] | select(.op == "join") | .inputs) =
    ["copied_rows", "copied_rows", "session_rows"]' \
  "$lineage_definition" >"$work/copy-extra-key.json"
for streaming in token-literal token-defined copy-extra-key; do
  "$binary" explain --definition "$work/$streaming.json" --projection rows --format json |
    jq -e '.strategy.kind == "partition-lineage-stream"' >/dev/null
  CODEX_HOME="$expression_home" "$binary" observe --definition "$work/$streaming.json" \
    --projection rows --session-id fixture-session --format json |
    jq -e '.corpus.files == 1 and (.data.rows | length) == 1' >/dev/null
done
"$binary" explain --definition "$work/token-read.json" --projection rows --format json |
  jq -e '.strategy.kind == "materialized-graph"' >/dev/null
if token_read=$(CODEX_HOME="$expression_home" "$binary" observe \
  --definition "$work/token-read.json" --projection rows --session-id fixture-session \
  --format json); then
  echo "a graph-input derive that reads the parsed token count streamed" >&2
  exit 1
fi
jq -e '.code == "ObservationStreamingLineageShapeUnsupported"' <<<"$token_read" >/dev/null
