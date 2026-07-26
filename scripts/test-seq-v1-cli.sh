#!/usr/bin/env bash
set -euo pipefail

binary=$1
message_definition=apps/seq/src/v1/fixtures/message-observation.json
external_definition=apps/seq/src/v1/fixtures/external-observation.json
external_facts=apps/seq/src/v1/fixtures/external-facts.json
ranked_definition=apps/seq/src/v1/fixtures/ranked-observation.json
ranked_facts=apps/seq/src/v1/fixtures/ranked-facts.json
rollout=apps/seq/src/v1/fixtures/rollout.jsonl
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
cache_dir=$(mktemp -d "$temp_base/seq-v1-smoke.XXXXXX")
trap 'test -n "${cache_dir:-}" && rm -rf -- "$cache_dir"' EXIT
export SEQ_CACHE_DIR="$cache_dir/cache"

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
grep -Fq '"schema":"seq-observation-result/v1"' <<<"$observation_output"
grep -Fq '"schema":"example-message-rows/v1"' <<<"$observation_output"
grep -Fq '"text":"Observed FAILURE evidence"' <<<"$observation_output"
grep -Fq '"source_event_id":"sha256:' <<<"$observation_output"
grep -Fq '"physical_passes":1' <<<"$observation_output"
grep -Fq '"files_opened":1' <<<"$observation_output"
grep -Fq '"rows_materialized":0' <<<"$observation_output"
grep -Fq '"authority_granted":false' <<<"$observation_output"

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

capabilities=$("$binary" capabilities --format json)
grep -Fq '"schema":"seq-capabilities/v1"' <<<"$capabilities"
grep -Fq '"observation_abis":["seq-observation-abi/v1"]' <<<"$capabilities"
grep -Fq '"id":"scan","version":1' <<<"$capabilities"
grep -Fq '"id":"filter","version":1' <<<"$capabilities"
grep -Fq '"id":"project","version":1' <<<"$capabilities"
grep -Fq '"id":"sort","version":1' <<<"$capabilities"
grep -Fq '"id":"distinct","version":1' <<<"$capabilities"
if grep -Eq '"id":"(join|aggregate|ordered-fold|reachability)"' \
  <<<"$capabilities"
then
  exit 1
fi
if grep -Eq \
  'actuat|universal|learnings|negative-ledger|synesthesia|SKDC|SDR|EPG' \
  <<<"$capabilities"
then
  exit 1
fi

help_output=$("$binary" --help)
grep -Fq 'definition check' <<<"$help_output"
grep -Fq 'observe' <<<"$help_output"
if grep -Eq 'skill-decision-audit|execution-policy-compile|actuation-audit' \
  <<<"$help_output"
then
  exit 1
fi
