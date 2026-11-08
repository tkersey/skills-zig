#!/usr/bin/env bash
set -euo pipefail
trap 'printf "observation contract check failed at line %s\n" "$LINENO" >&2' ERR

binary=$1
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
  --arg path "$PWD/$rollout" '
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
  --path "$PWD/apps/seq/src/v1/fixtures/../fixtures/rollout.jsonl" \
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
