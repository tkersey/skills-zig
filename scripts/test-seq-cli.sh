#!/usr/bin/env bash
set -euo pipefail

binary=$1
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID PI_SESSION_ID PI_SESSION_FILE
bash scripts/test-seq-observation-contract.sh "$binary"
message_definition=apps/seq/src/v1/fixtures/message-observation.json
external_definition=apps/seq/src/v1/fixtures/external-observation.json
external_facts=apps/seq/src/v1/fixtures/external-facts.json
ranked_definition=apps/seq/src/v1/fixtures/ranked-observation.json
ranked_facts=apps/seq/src/v1/fixtures/ranked-facts.json
rollout=apps/seq/src/v1/fixtures/rollout.jsonl
opencode_history=apps/seq/src/v1/fixtures/opencode/prompt-history.jsonl
pi_session=apps/seq/src/v1/fixtures/pi/session.jsonl
nested_outputs=libs/trace_core/testdata/nested_tool_outputs.jsonl
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
cache_dir=$(mktemp -d "$temp_base/seq-v1-smoke.XXXXXX")
trap 'test -n "${cache_dir:-}" && rm -rf -- "$cache_dir"' EXIT
export SEQ_CACHE_DIR="$cache_dir/cache"
fixture_root="$cache_dir/fixture-root"
cp -R apps/seq/src/v1/fixtures "$fixture_root"
rm -rf -- "$fixture_root/claude"

check_output=$("$binary" definition check \
  --definition "$message_definition" \
  --format json)
grep -Fq '"schema":"seq-definition-check-result/v1"' <<<"$check_output"
grep -Fq '"valid":true' <<<"$check_output"
grep -Fq '"cache_hit":false' <<<"$check_output"
grep -Fq '"authority_granted":false' <<<"$check_output"

warm_check_output=$("$binary" definition check \
  --definition "$message_definition" \
  --format json)
grep -Fq '"valid":true' <<<"$warm_check_output"
grep -Fq '"cache_hit":true' <<<"$warm_check_output"

plan_file=$(find \
  "$SEQ_CACHE_DIR/definitions/plans" \
  -type f \
  -print \
  -quit)
test -n "$plan_file"
printf '%s\n' 'corrupt-cache-entry' >"$plan_file"
rebuilt_check_output=$("$binary" definition check \
  --definition "$message_definition" \
  --format json)
grep -Fq '"valid":true' <<<"$rebuilt_check_output"
grep -Fq '"cache_hit":false' <<<"$rebuilt_check_output"

observation_output=$("$binary" observe \
  --definition "$message_definition" \
  --projection rows \
  --path "$rollout" \
  --param needle=failure \
  --format json)
grep -Fq '"schema":"seq-observation-result/v2"' <<<"$observation_output"
grep -Fq '"schema":"example-message-rows/v1"' <<<"$observation_output"
grep -Fq '"text":"Observed FAILURE evidence"' <<<"$observation_output"
grep -Fq '"source_event_id":"sha256:' <<<"$observation_output"
grep -Fq '"physical_passes":1' <<<"$observation_output"
grep -Fq '"files_opened":1' <<<"$observation_output"
grep -Fq '"rows_materialized":0' <<<"$observation_output"
grep -Fq '"authority_granted":false' <<<"$observation_output"

stdin_observation_output=$("$binary" observe \
  --definition "$external_definition" \
  --input facts=- \
  --projection rows \
  --format json \
  <"$external_facts")
grep -Fq '"files_opened":0' <<<"$stdin_observation_output"
grep -Fq '"files":0' <<<"$stdin_observation_output"

opencode_output=$("$binary" observe \
  --definition "$message_definition" \
  --projection rows \
  --path "$opencode_history" \
  --param needle=verifier \
  --format json)
grep -Fq '"adapter":"opencode-prompt-history-jsonl/v1"' <<<"$opencode_output"
grep -Fq '"session_id":"opencode-session:' <<<"$opencode_output"
grep -Fq '"text":"run the verifier"' <<<"$opencode_output"
grep -Fq '"physical_passes":1' <<<"$opencode_output"
grep -Fq '"files_opened":1' <<<"$opencode_output"

opencode_sessions=$("$binary" sessions \
  --root apps/seq/src/v1/fixtures/opencode \
  --format json)
opencode_session_id=$(jq -er '.[0].session_id' <<<"$opencode_sessions")
[[ "$opencode_session_id" == opencode-session:* ]]
grep -Fq '"originator":"opencode"' <<<"$opencode_sessions"

opencode_turns=$("$binary" turns \
  --path "$opencode_history" \
  --format json)
grep -Fq "\"session_id\":\"$opencode_session_id\"" <<<"$opencode_turns"
grep -Fq '"user_message":"run the verifier"' <<<"$opencode_turns"

opencode_tools=$("$binary" tool-lifecycle \
  --path "$opencode_history" \
  --format json)
grep -Fq "\"session_id\":\"$opencode_session_id\"" <<<"$opencode_tools"
grep -Fq '"lifecycle_status":"completed"' <<<"$opencode_tools"
grep -Fq '"output_text":"ok"' <<<"$opencode_tools"

opencode_query=$("$binary" query \
  --path "$opencode_history" \
  --spec '{"dataset":"turns","select":["session_id","turn_index","user_message"],"limit":5,"format":"json"}')
grep -Fq '"user_message":"inspect the adapter"' <<<"$opencode_query"
if opencode_structured_error=$("$binary" query \
  --path "$opencode_history" \
  --spec '{"dataset":"structured_values","select":["document_id"],"limit":5,"format":"json"}' \
  2>&1)
then
  exit 1
fi
grep -Fq '"code":"OpenCodeStructuredValuesUnavailable"' \
  <<<"$opencode_structured_error"

pi_sessions=$("$binary" sessions --root apps/seq/src/v1/fixtures/pi --format json)
jq -e 'length == 1 and (.[0] | .session_id == "pi-fixture" and
  .originator == "pi" and .cwd == "/pi-fixture-repo" and .turn_count == 2 and
  .thread_name == "Pi branch fixture" and .total_tokens == 80 and
  .input_tokens == 65 and .cached_input_tokens == 2 and .output_tokens == 15 and
  .parent_session_id == null)' <<<"$pi_sessions" >/dev/null

pi_turns=$("$binary" turns --path "$pi_session" --format json)
jq -e 'length == 2 and
  (any(.[]; .turn_index == 1 and .final_answer == "Alternative Pi FAILURE answer")) and
  (any(.[]; .turn_index == 2 and .final_answer == "Second Pi answer"))' \
  <<<"$pi_turns" >/dev/null
if grep -Fq 'PRIVATE_PI_REASONING' <<<"$pi_turns"; then
  exit 1
fi

pi_observation=$("$binary" observe \
  --definition "$message_definition" --projection rows \
  --path "$pi_session" --param needle=failure --format json)
grep -Fq '"adapter":"pi-session-jsonl/v1"' <<<"$pi_observation"
grep -Fq '"text":"inspect Pi FAILURE evidence"' <<<"$pi_observation"
grep -Fq '"text":"Alternative Pi FAILURE answer"' <<<"$pi_observation"
grep -Fq '"source_event_id":"sha256:' <<<"$pi_observation"

pi_graph_definition=apps/seq/src/v1/fixtures/pi/graph-observation.json
mkdir -p "$cache_dir/codex/sessions"
cp "$rollout" "$cache_dir/codex/sessions/rollout.jsonl"
pi_graph=$(CODEX_HOME="$cache_dir/codex" "$binary" observe \
  --definition "$pi_graph_definition" --projection rows --path "$pi_session" --format json)
jq -e '.corpus.adapter == "pi-session-jsonl/v1" and .corpus.files == 1 and
  .data.rows[0].session_id == "pi-fixture"' <<<"$pi_graph" >/dev/null
pi_graph_root=$("$binary" observe --definition "$pi_graph_definition" --projection rows \
  --root apps/seq/src/v1/fixtures/pi --format json)
jq -e '.corpus.files == 1 and (.data.rows | length == 1) and
  .data.rows[0].session_id == "pi-fixture"' <<<"$pi_graph_root" >/dev/null

pi_messages=$("$binary" query --path "$pi_session" \
  --spec '{"dataset":"messages","select":["text"],"limit":100,"format":"json"}')
grep -Fq 'Original Pi answer' <<<"$pi_messages"
grep -Fq 'Alternative Pi FAILURE answer' <<<"$pi_messages"
if grep -Fq 'PRIVATE_PI_REASONING' <<<"$pi_messages"; then
  exit 1
fi

pi_payloads=$("$binary" query --path "$pi_session" \
  --spec '{"dataset":"source_events","select":["source_event_id","payload_json","format"],"limit":100,"format":"json"}')
jq -e 'any(.[]; .payload_json.id == "a4" and .payload_json.parentId == "u1" and
  .format == "pi_session_jsonl")' <<<"$pi_payloads" >/dev/null
if grep -Eq 'PRIVATE_PI_REASONING|PRIVATE_PI_TOOL_SIGNATURE' <<<"$pi_payloads"; then
  exit 1
fi
pi_raw=$("$binary" query --path "$pi_session" \
  --spec '{"dataset":"source_events","select":["source_event_id","raw_json"],"limit":100,"format":"json"}')
grep -Fq 'PRIVATE_PI_REASONING' <<<"$pi_raw"
grep -Fq 'PRIVATE_PI_TOOL_SIGNATURE' <<<"$pi_raw"
test "$(jq -c 'map(.source_event_id)' <<<"$pi_payloads")" = \
  "$(jq -c 'map(.source_event_id)' <<<"$pi_raw")"

pi_tools=$("$binary" tool-lifecycle --path "$pi_session" --format json)
jq -e 'length == 1 and (.[0] | .tool_name == "bash" and .turn_index == 1 and
  .lifecycle_status == "completed" and .output_text == "{\"status\":\"ok\"}")' \
  <<<"$pi_tools" >/dev/null
pi_structured=$("$binary" query --path "$pi_session" \
  --spec '{"dataset":"structured_values","select":["json_pointer","scalar_value"],"limit":10,"format":"json"}')
jq -e 'any(.[]; .json_pointer == "/status" and .scalar_value == "ok")' \
  <<<"$pi_structured" >/dev/null
test "$("$binary" session-graph --path "$pi_session" --format json)" = '[]'

pi_tail=$(CODEX_THREAD_ID= PI_SESSION_ID= PI_SESSION_FILE="$PWD/$pi_session" \
  "$binary" tail --current --once --format json)
grep -Fq '"format":"pi_session_jsonl"' <<<"$pi_tail"
pi_find=$("$binary" find-session --root apps/seq/src/v1/fixtures/pi \
  --session-id pi-fixture --format json)
grep -Fq '"session_id":"pi-fixture"' <<<"$pi_find"

if pi_usage_error=$("$binary" query --path "$pi_session" \
  --spec '{"dataset":"token_events","select":["total_tokens"],"format":"json"}' 2>&1)
then
  exit 1
fi
grep -Fq '"code":"PiCumulativeTokenEventsUnavailable"' <<<"$pi_usage_error"

claude_fixtures=apps/seq/src/v1/fixtures/claude
"$binary" capabilities --format json |
  jq -e '.source_adapters | any(.[]; . == "claude-code-transcript-jsonl/v1")' >/dev/null
claude_outcomes="$cache_dir/turn-outcomes.jsonl"
cp "$claude_fixtures/turn-outcomes.jsonl" "$claude_outcomes"
touch -t 202001010000 "$claude_outcomes"
claude_turns=$("$binary" turns --path "$claude_outcomes" --format json)
jq -e 'map(.status_reason) == ["claude_end_turn", "claude_tool_ended_turn",
  "claude_interrupted", "claude_text_end", "claude_superseded", "stale_ongoing_file"]' \
  <<<"$claude_turns" >/dev/null
jq -e 'map(.origin) == ["human", "sdk", "human", "human", "human", "human"]' \
  <<<"$claude_turns" >/dev/null
claude_tokens=$("$binary" query --path "$claude_fixtures/request-records.jsonl" \
  --spec '{"dataset":"token_events","select":["request_key","request_record","usage_model","usage_finality","quantity_state","has_total_usage","total_tokens"],"format":"json"}')
jq -e 'length == 2 and all(.[]; .request_record == "here" and .usage_model == "per-request" and
  .usage_finality == "final" and .quantity_state == "usable" and .has_total_usage == false)' \
  <<<"$claude_tokens" >/dev/null
claude_observation=$("$binary" observe --definition "$message_definition" --projection rows \
  --path "$claude_fixtures/turn-outcomes.jsonl" --param needle=a --format json)
grep -Fq '"adapter":"claude-code-transcript-jsonl/v1"' <<<"$claude_observation"
if claude_conflict=$("$binary" sessions --source claude-code --root "$claude_fixtures" \
  --format json); then
  exit 1
fi
jq -e '.code == "ConflictingSourceSelectors"' <<<"$claude_conflict" >/dev/null
claude_config="$cache_dir/claude-config"
claude_project="$claude_config/projects/-repo"
claude_current_id=b1000000-0000-4000-8000-000000000001
mkdir -p "$claude_project"
cp "$claude_fixtures/fork-parent/$claude_current_id.jsonl" "$claude_project/"
claude_default=$(CLAUDE_CONFIG_DIR="$claude_config" "$binary" sessions --source claude-code \
  --format json)
jq -e --arg id "$claude_current_id" 'length == 1 and .[0].session_id == $id' \
  <<<"$claude_default" >/dev/null
claude_tail=$(CLAUDE_CONFIG_DIR="$claude_config" CLAUDE_CODE_SESSION_ID="$claude_current_id" \
  "$binary" tail --current --once --limit 1 --format json)
grep -Fq '"format":"claude_code_jsonl"' <<<"$claude_tail"
if claude_ambiguous=$(CLAUDE_CONFIG_DIR="$claude_config" CODEX_THREAD_ID=codex-hint \
  CLAUDE_CODE_SESSION_ID="$claude_current_id" "$binary" tail --current --once --format json); then
  exit 1
fi
jq -e '.code == "AmbiguousCurrentSessionSource"' <<<"$claude_ambiguous" >/dev/null
claude_selected=$(CLAUDE_CONFIG_DIR="$claude_config" CODEX_THREAD_ID=codex-hint \
  CLAUDE_CODE_SESSION_ID="$claude_current_id" "$binary" tail --current --once --source claude-code \
  --limit 1 --format json)
grep -Fq "\"session_id\":\"$claude_current_id\"" <<<"$claude_selected"
if claude_missing=$(CLAUDE_CONFIG_DIR="$claude_config" CODEX_THREAD_ID=codex-hint \
  "$binary" tail --current --once --source claude-code --format json); then
  exit 1
fi
jq -e '.code == "CurrentSessionUnavailable"' <<<"$claude_missing" >/dev/null
if claude_explain=$("$binary" explain --definition "$message_definition" --projection rows \
  --source claude-code --format json); then
  exit 1
fi
jq -e '.code == "ExplainDoesNotReadCorpus"' <<<"$claude_explain" >/dev/null
if claude_undeclared=$("$binary" observe --definition "$message_definition" --projection rows \
  --source claude-code --param needle=a --format json); then
  exit 1
fi
jq -e '.code == "ObservationSelectorNotDeclared"' <<<"$claude_undeclared" >/dev/null

claude_definitions=$claude_fixtures/observations
claude_family="$cache_dir/claude-outside"
claude_root_id=d0000000-0000-4000-8000-000000000001
claude_worker_id=$claude_root_id/agent-a1b2c3d4e5f600001
mkdir -p "$claude_family" "$cache_dir/home" "$cache_dir/pi"
cp -R "$claude_fixtures/worker/proj" "$claude_family/proj"
claude_root_path="$claude_family/proj/$claude_root_id.jsonl"
claude_isolated() {
  HOME="$cache_dir/home" CODEX_HOME="$cache_dir/codex" CLAUDE_CONFIG_DIR="$claude_config" \
    PI_CODING_AGENT_DIR="$cache_dir/pi" PI_CODING_AGENT_SESSION_DIR="$cache_dir/pi" \
    "$binary" "$@"
}
claude_lineage=$(claude_isolated observe --definition "$claude_definitions/family-lineage.json" \
  --projection rows --path "$claude_root_path" --format json)
jq -e --arg root "$claude_root_id" --arg worker "$claude_worker_id" '
  .corpus.files == 2 and .corpus.sessions == 2 and
  (.data.rows | map(.session_id) | sort) == [$root, $worker] and
  .stats.discovery_files_opened > 0 and .limitations == []' <<<"$claude_lineage" >/dev/null
claude_reachable=$(claude_isolated observe --definition "$pi_graph_definition" \
  --projection rows --path "$claude_root_path" --format json)
jq -e --arg root "$claude_root_id" '.corpus.files == 2 and .corpus.sessions == 2 and
  (.data.rows | map(.session_id)) == [$root]' <<<"$claude_reachable" >/dev/null
claude_root_bytes=$(wc -c <"$claude_root_path")
claude_joined=$(claude_isolated observe --definition "$claude_definitions/session-self-join.json" \
  --projection rows --path "$claude_root_path" --format json)
jq -e --arg root "$claude_root_id" --argjson bytes "$claude_root_bytes" '
  .corpus.files == 1 and .corpus.sessions == 1 and .data.rows == [{"session_id": $root}] and
  .stats.files_opened == 1 and .stats.discovery_files_opened == 0 and
  .stats.discovery_bytes_read == 0 and .stats.corpus_bytes_read == $bytes' \
  <<<"$claude_joined" >/dev/null

claude_window=$claude_fixtures/time-window/projects
claude_late_id=e0000000-0000-4000-8000-000000000002
claude_present=$(claude_isolated observe --definition "$claude_definitions/session-self-join.json" \
  --projection rows --root "$claude_window" --session-id "$claude_late_id" --format json)
jq -e --arg id "$claude_late_id" '.data.rows == [{"session_id": $id}]' \
  <<<"$claude_present" >/dev/null
if claude_pruned=$(claude_isolated observe \
  --definition "$claude_definitions/session-self-join.json" --projection rows \
  --root "$claude_window" --session-id "$claude_late_id" --until 2026-11-01T00:00:00Z \
  --format json); then
  exit 1
fi
jq -e '.code == "SessionNotFound"' <<<"$claude_pruned" >/dev/null
claude_native_late=$(claude_isolated turns --root "$claude_window" \
  --session-id "$claude_late_id" --until 2026-11-01T00:00:00Z --format json)
test "$claude_native_late" = '[]'
if claude_native_absent=$(claude_isolated turns --root "$claude_window" \
  --session-id e0000000-0000-4000-8000-0000000000ff --until 2026-11-01T00:00:00Z \
  --format json); then
  exit 1
fi
jq -e '.code == "SessionNotFound"' <<<"$claude_native_absent" >/dev/null

claude_excluded=$(claude_isolated observe --definition "$claude_definitions/session-exclusion.json" \
  --projection rows --root "$claude_family" --param "exclude_session_id=$claude_root_id" \
  --format json)
jq -e --arg worker "$claude_worker_id" '
  .data.rows == [{"session_id": $worker, "lineage_conflict": false}] and
  (.limitations | all(startswith("claude_worker_parent_missing") | not))' \
  <<<"$claude_excluded" >/dev/null
claude_worker_only=$(claude_isolated observe \
  --definition "$claude_definitions/session-exclusion.json" --projection rows \
  --root "$claude_family" --session-id "$claude_worker_id" --param exclude_session_id=none \
  --format json)
jq -e --arg worker "$claude_worker_id" '
  .data.rows == [{"session_id": $worker, "lineage_conflict": false}] and
  (.limitations | all(startswith("claude_worker_parent_missing") | not))' \
  <<<"$claude_worker_only" >/dev/null
claude_orphan_root="$cache_dir/claude-orphan"
claude_orphan_id=d0000000-0000-4000-8000-000000000005
cp -R "$claude_fixtures/worker-missing-parent" "$claude_orphan_root"
jq '.selectors += ["session-id"]' "$claude_definitions/family-lineage.json" \
  >"$cache_dir/family-lineage-selected.json"
claude_orphan=$(claude_isolated observe --definition "$cache_dir/family-lineage-selected.json" \
  --projection rows --root "$claude_orphan_root" --session-id "$claude_orphan_id" --format json)
jq -e '.corpus.files == 1 and (.limitations | index("claude_worker_parent_missing: 1") != null)' \
  <<<"$claude_orphan" >/dev/null
claude_conflict_root="$cache_dir/claude-identity-conflict"
cp -R "$claude_fixtures/worker-identity-conflict" "$claude_conflict_root"
jq '.selectors += ["session-id"] | .requires.operators += ["filter"] |
  .relations[0].fields += ["lineage_conflict"] |
  .pipeline = [.pipeline[0],
    {"op": "filter", "input": "session_rows", "as": "clean",
      "where": [{"field": "lineage_conflict", "op": "eq", "value": false}]},
    (.pipeline[1] | .inputs = ["clean", "clean", "clean"])]' \
  "$claude_definitions/family-lineage.json" >"$cache_dir/lineage-filter.json"
claude_restaged=$(claude_isolated observe --definition "$cache_dir/lineage-filter.json" \
  --projection rows --root "$claude_conflict_root" \
  --session-id d0000000-0000-4000-8000-000000000006 --format json)
jq -e '(.data.rows | map(.session_id)) == ["d0000000-0000-4000-8000-000000000006"] and
  .corpus.parser_warning_count > 0' <<<"$claude_restaged" >/dev/null
claude_truncated_root="$cache_dir/claude-truncated"
mkdir -p "$claude_truncated_root/proj"
cp "$claude_fixtures/worker/proj/$claude_root_id.jsonl" "$claude_truncated_root/proj/"
printf '{"type":"user","uuid":"u1","sessi' \
  >"$claude_truncated_root/proj/e0000000-0000-4000-8000-000000000002.jsonl"
claude_truncated=$(claude_isolated observe \
  --definition "$claude_definitions/session-exclusion.json" --projection rows \
  --root "$claude_truncated_root" --param exclude_session_id=none --format json)
jq -e '.corpus.adapter == "claude-code-transcript-jsonl/v1" and
  .corpus.parser_warning_count == 1' <<<"$claude_truncated" >/dev/null
pi_malformed_root="$cache_dir/pi-malformed"
mkdir -p "$pi_malformed_root"
cp "$pi_session" "$pi_malformed_root/"
printf '{not json\n' >"$pi_malformed_root/z.jsonl"
jq '.relations[0].fields = ["session_id"] | .pipeline[2].fields = ["session_id"] |
  .projections.rows.fields = ["session_id"]' "$claude_definitions/session-exclusion.json" \
  >"$cache_dir/session-ids.json"
if pi_mixed=$(claude_isolated observe --definition "$cache_dir/session-ids.json" \
  --projection rows --root "$pi_malformed_root" --param exclude_session_id=none --format json); then
  exit 1
fi
jq -e '.code == "MixedPhysicalSourceAdapters"' <<<"$pi_mixed" >/dev/null

external_output=$("$binary" observe \
  --definition "$external_definition" \
  --projection rows \
  --input "facts=$external_facts" \
  --format json)
grep -Fq '"adapter":"immutable-relation-json/v1"' <<<"$external_output"
grep -Fq '"rows":[{"id":"second"}]' <<<"$external_output"
grep -Fq '"authority_granted":false' <<<"$external_output"

ranked_output=$("$binary" observe \
  --definition "$ranked_definition" \
  --projection rows \
  --input "facts=$ranked_facts" \
  --format json)
grep -Fq \
  '"rows":[{"id":"c","score":3},{"id":"e","score":1},{"id":"b","score":null}]' \
  <<<"$ranked_output"
grep -Fq '"rows_scanned":5' <<<"$ranked_output"
grep -Fq '"rows_materialized":5' <<<"$ranked_output"
grep -Fq '"output_rows":3' <<<"$ranked_output"

explain_output=$("$binary" explain \
  --definition "$message_definition" \
  --projection rows \
  --param needle=failure \
  --format json)
grep -Fq '"schema":"seq-observation-plan/v1"' <<<"$explain_output"
grep -Fq '"relation":"messages"' <<<"$explain_output"
grep -Fq '"corpus_read":false' <<<"$explain_output"

sessions_output=$("$binary" sessions \
  --root "$fixture_root" \
  --format json)
grep -Fq '"session_id":"fixture-session"' <<<"$sessions_output"

turns_output=$("$binary" turns --path "$rollout" --format json)
grep -Fq '"turn_id":"turn-1"' <<<"$turns_output"

two_turn_rollout=libs/trace_core/testdata/old_2025_08_root_meta.jsonl
limited_turns=$("$binary" turns \
  --path "$two_turn_rollout" \
  --limit 1 \
  --format json)
test "$(grep -o '"turn_index":' <<<"$limited_turns" | wc -l | tr -d ' ')" = 1

selected_turn=$("$binary" turns \
  --path "$two_turn_rollout" \
  --since 2025-08-01T10:01:01Z \
  --contains SECOND \
  --status complete \
  --format json)
grep -Fq '"turn_index":2' <<<"$selected_turn"
if grep -Fq '"turn_index":1' <<<"$selected_turn"; then
  exit 1
fi

inclusive_turn=$("$binary" turns \
  --path "$two_turn_rollout" \
  --until 2025-08-01T10:00:01Z \
  --format json)
grep -Fq '"turn_index":1' <<<"$inclusive_turn"
if grep -Fq '"turn_index":2' <<<"$inclusive_turn"; then
  exit 1
fi

detail_output=$("$binary" session-detail --path "$rollout" --format json)
grep -Fq '"authority_granted":false' <<<"$detail_output"
grep -Fq '"final_answer":"Observed FAILURE evidence"' <<<"$detail_output"

test "$("$binary" tool-lifecycle --path "$rollout" --format json)" = '[]'
test "$("$binary" session-graph --path "$rollout" --format json)" = '[]'

nested_results=$("$binary" query --path "$nested_outputs" \
  --spec '{"dataset":"tool_results","where":[{"field":"call_id","op":"exact","value":"batch"}],"select":["call_id","exit_code","source_event_id","output_parts_json"],"limit":1,"format":"json"}')
jq -e 'length == 1 and (.[0] | .source_event_id as $source |
  .output_parts_json as $parts |
  .exit_code == 0 and
  ($source | startswith("sha256:")) and
  ($parts | length) == 2 and
  ($parts | all(.source_event_id == $source)) and
  $parts[0].payload_pointer == "/output/0/text" and
  $parts[0].process_results[0].exit_code == 3 and
  $parts[0].process_results[0].process_status == "failed" and
  $parts[1].process_results[0].exit_code == 0 and
  $parts[1].process_results[0].process_status == "completed" and
  $parts[1].process_results[1].exit_code == null and
  $parts[1].process_results[1].process_status == "unknown")' \
  <<<"$nested_results" >/dev/null

nested_lifecycle=$("$binary" tool-lifecycle --path "$nested_outputs" --format json)
jq -e 'length == 6 and
  (map(select(.call_id == "progress"))[0] |
    .exit_code == null and
    (.output_parts_json | length) == 2 and
    .output_parts_json[0].process_results[0].process_status == "running" and
    .output_parts_json[1].process_results[0].exit_code == 7) and
  (map(select(.call_id == "readback"))[0] |
    (.output_parts_json[0].process_results | length) == 1 and
    .output_parts_json[0].process_results[0].exit_code == 0)' \
  <<<"$nested_lifecycle" >/dev/null

nested_detail=$("$binary" session-detail --path "$nested_outputs" --format json)
jq -e --argjson lifecycle "$nested_lifecycle" '.tools == $lifecycle' \
  <<<"$nested_detail" >/dev/null

tail_output=$("$binary" tail --path "$rollout" --once --format json)
grep -Fq '"entry_type":"session_meta"' <<<"$tail_output"
grep -Fq '"entry_type":"event_msg"' <<<"$tail_output"

find_output=$("$binary" find-session \
  --root "$fixture_root" \
  --session-id fixture-session \
  --format json)
grep -Fq '"session_id":"fixture-session"' <<<"$find_output"

datasets_output=$("$binary" datasets --format json)
grep -Fq '"dataset":"structured_values"' <<<"$datasets_output"
if grep -Eq 'actuat|universal|learnings|negative-ledger|synesthesia' \
  <<<"$datasets_output"
then
  exit 1
fi
if "$binary" datasets --root apps/seq/src/v1/fixtures >/dev/null 2>&1; then
  exit 1
fi

schema_output=$("$binary" dataset-schema \
  --dataset structured_values \
  --format json)
grep -Fq '"field":"json_pointer"' <<<"$schema_output"

query_output=$("$binary" query \
  --root "$fixture_root" \
  --spec '{"dataset":"messages","where":[{"field":"text","op":"contains","value":"failure","case_insensitive":true}],"select":["session_id","role","text"],"limit":5,"format":"json"}')
grep -Fq \
  '{"session_id":"fixture-session","role":"assistant","text":"Observed FAILURE evidence"}' \
  <<<"$query_output"
if "$binary" query \
  --limit 1 \
  --spec '{"dataset":"sessions","select":["session_id"]}' \
  >/dev/null 2>&1
then
  exit 1
fi
if "$binary" query \
  --path "$rollout" \
  --spec '{"dataset":"sessions","select":["session_id","session_id"],"format":"json"}' \
  >/dev/null 2>&1
then
  exit 1
fi

mkdir -p "$cache_dir/sessions"
cp "$rollout" "$cache_dir/sessions/rollout.jsonl"
index_output=$("$binary" index build \
  --root "$cache_dir/sessions" \
  --format json)
grep -Fq '"schema":"seq-index-result/v1"' <<<"$index_output"
grep -Fq '"action":"build"' <<<"$index_output"
grep -Fq '"files":1' <<<"$index_output"
test ! -e "$cache_dir/sessions/.seq-index.jsonl"

capabilities=$("$binary" capabilities --format json)
grep -Fq '"schema":"seq-capabilities/v1"' <<<"$capabilities"
grep -Fq '"observation_abis":["seq-observation-abi/v1"]' <<<"$capabilities"
grep -Fq '"id":"scan","version":2' <<<"$capabilities"
grep -Fq '"id":"filter","version":3' <<<"$capabilities"
grep -Fq '"id":"project","version":1' <<<"$capabilities"
grep -Fq '"id":"derive","version":3' <<<"$capabilities"
grep -Fq '"id":"join","version":1' <<<"$capabilities"
grep -Fq '"id":"aggregate","version":2' <<<"$capabilities"
grep -Fq '"id":"sort","version":1' <<<"$capabilities"
grep -Fq '"id":"top-k","version":1' <<<"$capabilities"
grep -Fq '"id":"distinct","version":1' <<<"$capabilities"
grep -Fq '"id":"ordered-fold","version":2' <<<"$capabilities"
grep -Fq '"source_encodings":["jsonl","jsonl.zst"]' <<<"$capabilities"
grep -Fq '"id":"reachability","version":1' <<<"$capabilities"
grep -Fq '"opencode-prompt-history-jsonl/v1"' <<<"$capabilities"
grep -Fq '"pi-session-jsonl/v1"' <<<"$capabilities"
grep -Fq '"seq-command-error/v1"' <<<"$capabilities"
grep -Fq '"seq-definition-check-result/v1"' <<<"$capabilities"
grep -Fq '"seq-definition-description/v1"' <<<"$capabilities"
grep -Fq '"seq-index-result/v1"' <<<"$capabilities"
grep -Fq '"seq-observation-plan/v1"' <<<"$capabilities"
grep -Fq '"seq-observation-result/v2"' <<<"$capabilities"
if grep -Eq \
  'actuat|universal|learnings|negative-ledger|synesthesia|SKDC|SDR|EPG' \
  <<<"$capabilities"
then
  exit 1
fi

help_output=$("$binary" --help)
grep -Fq 'definition check' <<<"$help_output"
grep -Fq 'observe' <<<"$help_output"
if "$binary" skill-decision-audit --help >/dev/null 2>&1; then
  exit 1
fi
if "$binary" definition capture --help >/dev/null 2>&1; then
  exit 1
fi
if grep -Eq 'skill-decision-audit|execution-policy-compile|actuation-audit' \
  <<<"$help_output"
then
  exit 1
fi
