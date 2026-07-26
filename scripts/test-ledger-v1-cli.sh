#!/usr/bin/env bash
set -euo pipefail

binary=$1
definition=apps/ledger/src/v1/fixtures/record-definition.json
valid_input=apps/ledger/src/v1/fixtures/record-valid.json
invalid_input=apps/ledger/src/v1/fixtures/record-invalid.json
event_definition=apps/ledger/src/v1/fixtures/event-definition.json
event_input=apps/ledger/src/v1/fixtures/event-one.json
event_two=apps/ledger/src/v1/fixtures/event-two.json
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
repo_dir=$(mktemp -d "$temp_base/ledger-v1-smoke.XXXXXX")
trap 'test -n "${repo_dir:-}" && rm -rf -- "$repo_dir"' EXIT

check_output=$("$binary" definition check \
  --definition "$definition" \
  --format json)
grep -Fq '"schema":"ledger-definition-check-result/v1"' <<<"$check_output"
grep -Fq '"valid":true' <<<"$check_output"

validation_output=$("$binary" validate \
  --definition "$definition" \
  --input "record=$valid_input" \
  --format json)
grep -Fq '"schema":"ledger-validation-result/v1"' <<<"$validation_output"
grep -Fq '"authority_granted":false' <<<"$validation_output"
grep -Fq '"storage_mutated":false' <<<"$validation_output"

materialization_output=$("$binary" materialize \
  --definition "$definition" \
  --input "record=$valid_input" \
  --format json)
grep -Fq '"schema":"ledger-materialization-result/v1"' <<<"$materialization_output"
grep -Fq '"artifact_id":"sha256:' <<<"$materialization_output"
grep -Fq '"storage_mutated":false' <<<"$materialization_output"

set +e
invalid_output=$("$binary" validate \
  --definition "$definition" \
  --input "record=$invalid_input" \
  --format json)
invalid_status=$?
set -e
test "$invalid_status" -eq 2
grep -Fq '"valid":false' <<<"$invalid_output"
grep -Fq '"code":"exact-object"' <<<"$invalid_output"

transaction_output=$("$binary" transact \
  --definition "$event_definition" \
  --operation append \
  --repo "$repo_dir" \
  --input "event=$event_input" \
  --param request=smoke-one \
  --format json)
grep -Fq '"schema":"ledger-transaction-result/v1"' <<<"$transaction_output"
grep -Fq '"result":"appended"' <<<"$transaction_output"
grep -Fq '"semantic_authority_granted":false' <<<"$transaction_output"
grep -Fq '"storage_mutated":true' <<<"$transaction_output"
test -f "$repo_dir/.ledger/example/events.jsonl"
test -d "$repo_dir/.ledger/.bindings"

idempotent_output=$("$binary" transact \
  --definition "$event_definition" \
  --operation append \
  --repo "$repo_dir" \
  --input "event=$event_input" \
  --param request=smoke-one \
  --format json)
grep -Fq '"result":"idempotent"' <<<"$idempotent_output"
grep -Fq '"storage_mutated":false' <<<"$idempotent_output"

set +e
conflict_output=$("$binary" transact \
  --definition "$event_definition" \
  --operation append \
  --repo "$repo_dir" \
  --input "event=$event_two" \
  --param request=smoke-one \
  --format json)
conflict_status=$?
set -e
test "$conflict_status" -eq 2
grep -Fq '"schema":"ledger-transaction-error/v1"' <<<"$conflict_output"
grep -Fq '"code":"IdempotencyConflict"' <<<"$conflict_output"
grep -Fq '"storage_mutated":null' <<<"$conflict_output"
grep -Fq '"storage_mutation_state":"unknown"' <<<"$conflict_output"
