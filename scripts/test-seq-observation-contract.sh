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
