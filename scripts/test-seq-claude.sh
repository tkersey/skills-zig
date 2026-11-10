#!/usr/bin/env bash
set -euo pipefail

binary=$1
fixture=libs/trace_core/src/fixtures/claude-session.jsonl
work=$(mktemp -d "${TMPDIR:-/tmp}/seq-claude.XXXXXX")
trap 'test -n "${work:-}" && rm -rf -- "$work"' EXIT
export SEQ_CACHE_DIR="$work/cache"
mkdir -p "$work/main" "$work/child" "$work/warning"
cp "$fixture" "$work/main/session.jsonl"

capabilities=$("$binary" capabilities --format json)
jq -e '(.source_adapters | index("claude-session-jsonl/v1")) != null and
  ((.transports // []) | index("github-gist/v1")) == null and
  (.result_schemas | index("seq-gist/v1")) == null' <<<"$capabilities" >/dev/null
if removed_gist=$("$binary" gist read --gist abcde --format json); then
  exit 1
fi
jq -e '.schema == "seq-command-error/v1" and .code == "UnknownCommand"' \
  <<<"$removed_gist" >/dev/null

sessions=$("$binary" sessions --root "$work/main" --repo /project --format json)
jq -e 'length == 1 and (.[0] | .session_id == "session-a" and
  .native_session_id == "session-a" and .agent_id == null and
  .originator == "claude-code" and .turn_count == 2 and
  .total_tokens == null and .token_usage_observation_count == null)' \
  <<<"$sessions" >/dev/null

turns=$("$binary" turns --path "$fixture" --format json)
jq -e 'length == 2 and
  any(.[]; .turn_index == 1 and .user_message == "Investigate the failure" and
    .final_answer == "Alternative first conclusion") and
  any(.[]; .turn_index == 2 and .user_message == "Continue the second task" and
    .final_answer == "Second conclusion" and .has_compaction)' <<<"$turns" >/dev/null

messages=$("$binary" query --path "$fixture" \
  --spec '{"dataset":"messages","select":["role","text","native_id","native_parent_id"],"limit":100,"format":"json"}')
jq -e '([.[] | select(.role == "user")] | length) == 2 and
  any(.[]; .native_id == "a5" and .native_parent_id == "u1" and
    .text == "Alternative first conclusion") and
  any(.[]; .native_id == "a3" and .text == "First conclusion")' <<<"$messages" >/dev/null

tools=$("$binary" tool-lifecycle --path "$fixture" --format json)
jq -e 'length == 2 and
  any(.[]; .call_id == "tool-1" and .tool_name == "Bash" and
    .lifecycle_status == "completed" and .exit_code == null and
    .output_text == "checks passed") and
  any(.[]; .call_id == "tool-2" and .lifecycle_status == "failed" and
    .exit_code == null and .output_text == "file missing")' <<<"$tools" >/dev/null

events=$("$binary" query --path "$fixture" \
  --spec '{"dataset":"source_events","select":["line_number","format","role","text","native_id","native_parent_id","payload_json"],"limit":100,"format":"json"}')
jq -e 'length == 12 and
  all(.[]; .format == "claude_session_jsonl") and
  any(.[]; .native_id == "r1" and .role == "tool" and .native_parent_id == "a1") and
  any(.[]; .native_id == "s1" and .role == "context") and
  any(.[]; .payload_json.subtype == "compact_boundary")' <<<"$events" >/dev/null
if grep -Fq 'PRIVATE_' <<<"$sessions$turns$messages$tools$events"; then
  exit 1
fi
raw=$("$binary" query --path "$fixture" \
  --spec '{"dataset":"source_events","select":["raw_json"],"limit":100,"format":"json"}')
grep -Fq 'PRIVATE_THOUGHT' <<<"$raw"

observation=$("$binary" observe \
  --definition apps/seq/src/v1/fixtures/message-observation.json \
  --path "$fixture" --param needle=conclusion --projection rows --format json)
jq -e '.corpus.adapter == "claude-session-jsonl/v1" and
  .corpus.parser_warning_count == 0 and (.data.rows | length) == 3 and
  .authority_granted == false' <<<"$observation" >/dev/null

found=$("$binary" find-session --root "$work/main" --session-id session-a --format json)
jq -e 'length == 1 and .[0].native_session_id == "session-a"' <<<"$found" >/dev/null
if tokens=$("$binary" query --path "$fixture" \
  --spec '{"dataset":"token_events","select":["source_ordinal"],"limit":100,"format":"json"}'); then
  exit 1
fi
jq -e '.schema == "seq-command-error/v1" and
  .code == "ClaudeCumulativeTokenEventsUnavailable"' <<<"$tokens" >/dev/null

jq -c 'if has("sessionId") then .agentId = "worker-a" | .isSidechain = true else . end' \
  "$fixture" >"$work/child/session.jsonl"
child=$("$binary" sessions --root "$work/child" --format json)
jq -e 'length == 1 and (.[0] | .session_id == "claude:session-a:agent:worker-a" and
  .native_session_id == "session-a" and .agent_id == "worker-a" and
  .root_session_id == "session-a" and .parent_session_id == null and
  .control_parent_session_id == null and .is_external_worker)' <<<"$child" >/dev/null
selected_child=$("$binary" turns --root "$work/child" \
  --session-id claude:session-a:agent:worker-a --format json)
jq -e 'length == 2 and all(.[]; .session_id == "claude:session-a:agent:worker-a")' \
  <<<"$selected_child" >/dev/null

jq -c 'if .uuid == "a3" then .message.content += [{type:"future-block",data:"unknown"}]
  else . end' "$fixture" >"$work/warning/session.jsonl"
if "$binary" sessions --root "$work/warning" --format json >"$work/warning.json"; then
  exit 1
fi
jq -se 'length == 1 and (.[0] | .schema == "seq-command-error/v1" and
  .code == "PhysicalSourceWarningsPresent" and .warning_count > 0)' \
  "$work/warning.json" >/dev/null

opencode=apps/seq/src/v1/fixtures/opencode/prompt-history.jsonl
opencode_identity=$("$binary" query --path "$opencode" \
  --spec '{"dataset":"sessions","select":["session_id","native_session_id","agent_id"],"format":"json"}')
jq -e 'length == 1 and .[0].native_session_id == null and .[0].agent_id == null' \
  <<<"$opencode_identity" >/dev/null
opencode_events=$("$binary" query --path "$opencode" \
  --spec '{"dataset":"source_events","select":["text","native_id","native_parent_id"],"format":"json"}')
opencode_messages=$("$binary" query --path "$opencode" \
  --spec '{"dataset":"messages","select":["text","native_id","native_parent_id"],"format":"json"}')
for rows in "$opencode_events" "$opencode_messages"; do
  jq -e 'length > 0 and all(.[]; .native_id == null and .native_parent_id == null)' \
    <<<"$rows" >/dev/null
done

printf '%s\n' 'Seq Claude smoke tests passed'
