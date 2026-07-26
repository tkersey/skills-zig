#!/usr/bin/env bash
set -euo pipefail

binary=$1
definition=apps/ledger/src/v1/fixtures/record-definition.json
valid_input=apps/ledger/src/v1/fixtures/record-valid.json
invalid_input=apps/ledger/src/v1/fixtures/record-invalid.json
event_definition=apps/ledger/src/v1/fixtures/event-definition.json
event_input=apps/ledger/src/v1/fixtures/event-one.json
event_two=apps/ledger/src/v1/fixtures/event-two.json
event_snapshot_definition=apps/ledger/src/v1/fixtures/event-snapshot-definition.json
event_snapshot_initial=apps/ledger/src/v1/fixtures/event-snapshot-initial.jsonl
event_snapshot_replacement=apps/ledger/src/v1/fixtures/event-snapshot-replacement.jsonl
chained_definition=apps/ledger/src/v1/fixtures/chained-event-definition.json
chained_one=apps/ledger/src/v1/fixtures/chained-event-one.json
chained_two=apps/ledger/src/v1/fixtures/chained-event-two.json
chained_invalid=apps/ledger/src/v1/fixtures/chained-event-invalid.json
chained_illegal=apps/ledger/src/v1/fixtures/chained-event-illegal.json
chained_existing=apps/ledger/src/v1/fixtures/chained-event-existing.jsonl
chained_existing_invalid=apps/ledger/src/v1/fixtures/chained-event-existing-invalid.jsonl
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
repo_dir=$(mktemp -d "$temp_base/ledger-v1-smoke.XXXXXX")
protocol_repo=$(mktemp -d "$temp_base/ledger-v1-protocol.XXXXXX")
protocol_bind_repo=$(mktemp -d "$temp_base/ledger-v1-protocol-bind.XXXXXX")
protocol_bind_invalid_repo=$(mktemp -d "$temp_base/ledger-v1-protocol-bind-invalid.XXXXXX")
legacy_repo=$(mktemp -d "$temp_base/ledger-v1-bind.XXXXXX")
invalid_repo=$(mktemp -d "$temp_base/ledger-v1-bind-invalid.XXXXXX")
trap 'for dir in "${repo_dir:-}" "${protocol_repo:-}" "${protocol_bind_repo:-}" "${protocol_bind_invalid_repo:-}" "${legacy_repo:-}" "${invalid_repo:-}"; do test -n "$dir" && rm -rf -- "$dir"; done' EXIT
export LEDGER_CACHE_DIR="$repo_dir/cache"

capabilities=$("$binary" capabilities --format json)
grep -Fq '"schema":"ledger-capabilities/v1"' <<<"$capabilities"
grep -Fq '"id":"exact-object","version":1' <<<"$capabilities"
grep -Fq '"id":"implies","version":2' <<<"$capabilities"
grep -Fq '"id":"total-partition","version":1' <<<"$capabilities"
grep -Fq '"id":"total-mapping","version":1' <<<"$capabilities"
grep -Fq '"id":"all","version":1' <<<"$capabilities"
grep -Fq '"id":"any","version":1' <<<"$capabilities"
grep -Fq '"id":"none","version":1' <<<"$capabilities"
grep -Fq '"id":"composite-identity","version":1' <<<"$capabilities"
grep -Fq '"id":"content-address","version":1' <<<"$capabilities"
grep -Fq '"id":"compare-and-append","version":1' <<<"$capabilities"
grep -Fq '"id":"tagged-union","version":1' <<<"$capabilities"
if grep -Eq \
  '"id":"(regex|relevance|text-render)"' \
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

check_output=$("$binary" definition check \
  --definition "$definition" \
  --format json)
grep -Fq '"schema":"ledger-definition-check-result/v1"' <<<"$check_output"
grep -Fq '"valid":true' <<<"$check_output"
grep -Fq '"cache_hit":false' <<<"$check_output"

warm_check_output=$("$binary" definition check \
  --definition "$definition" \
  --format json)
grep -Fq '"valid":true' <<<"$warm_check_output"
grep -Fq '"cache_hit":true' <<<"$warm_check_output"

plan_file=$(find \
  "$LEDGER_CACHE_DIR/definitions/plans" \
  -type f \
  -print \
  -quit)
test -n "$plan_file"
printf '%s\n' 'corrupt-cache-entry' >"$plan_file"
rebuilt_check_output=$("$binary" definition check \
  --definition "$definition" \
  --format json)
grep -Fq '"valid":true' <<<"$rebuilt_check_output"
grep -Fq '"cache_hit":false' <<<"$rebuilt_check_output"

recovered_check_output=$("$binary" definition check \
  --definition "$definition" \
  --format json)
grep -Fq '"valid":true' <<<"$recovered_check_output"
grep -Fq '"cache_hit":true' <<<"$recovered_check_output"

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
test -d "$repo_dir/.ledger/.definitions"
compgen -G "$repo_dir/.ledger/.definitions/*.json" >/dev/null

projection_output=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$repo_dir" \
  --format json)
grep -Fq '"schema":"ledger-projection-result/v1"' <<<"$projection_output"
grep -Fq '"data":[{"kind":"one","value":1}]' <<<"$projection_output"
grep -Fq '"authority_granted":false' <<<"$projection_output"
grep -Fq '"storage_mutated":false' <<<"$projection_output"

projection_payload=$("$binary" project \
  --definition "$event_definition" \
  --projection latest \
  --repo "$repo_dir" \
  --payload-only \
  --format json)
test "$projection_payload" = '[{"kind":"one","value":1}]'

doctor_output=$("$binary" doctor \
  --definition "$event_definition" \
  --repo "$repo_dir" \
  --format json)
grep -Fq '"schema":"ledger-doctor-result/v1"' <<<"$doctor_output"
grep -Fq '"healthy":true' <<<"$doctor_output"
grep -Fq '"binding_rows":1' <<<"$doctor_output"
grep -Fq '"storage_mutated":false' <<<"$doctor_output"

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

chained_check=$("$binary" definition check \
  --definition "$chained_definition" \
  --format json)
grep -Fq '"valid":true' <<<"$chained_check"

chained_warm_check=$("$binary" definition check \
  --definition "$chained_definition" \
  --format json)
grep -Fq '"valid":true' <<<"$chained_warm_check"
grep -Fq '"cache_hit":true' <<<"$chained_warm_check"

chained_first=$("$binary" transact \
  --definition "$chained_definition" \
  --operation append \
  --repo "$protocol_repo" \
  --input "event=$chained_one" \
  --param request=chain-one \
  --format json)
grep -Fq '"result":"appended"' <<<"$chained_first"

chained_second=$("$binary" transact \
  --definition "$chained_definition" \
  --operation append \
  --repo "$protocol_repo" \
  --input "event=$chained_two" \
  --param request=chain-two \
  --format json)
grep -Fq '"result":"appended"' <<<"$chained_second"

chained_duplicate=$("$binary" transact \
  --definition "$chained_definition" \
  --operation append \
  --repo "$protocol_repo" \
  --input "event=$chained_two" \
  --param request=chain-two \
  --format json)
grep -Fq '"result":"idempotent"' <<<"$chained_duplicate"
grep -Fq '"storage_mutated":false' <<<"$chained_duplicate"

set +e
chained_failure=$("$binary" transact \
  --definition "$chained_definition" \
  --operation append \
  --repo "$protocol_repo" \
  --input "event=$chained_invalid" \
  --param request=chain-invalid \
  --format json)
chained_failure_status=$?
set -e
test "$chained_failure_status" -eq 2
grep -Fq '"code":"EventPreviousDigestMismatch"' <<<"$chained_failure"

set +e
chained_illegal_failure=$("$binary" transact \
  --definition "$chained_definition" \
  --operation append \
  --repo "$protocol_repo" \
  --input "event=$chained_illegal" \
  --param request=chain-illegal \
  --format json)
chained_illegal_failure_status=$?
set -e
test "$chained_illegal_failure_status" -eq 2
grep -Fq '"code":"IllegalReducerTransition"' <<<"$chained_illegal_failure"

chained_projection=$("$binary" project \
  --definition "$chained_definition" \
  --projection all \
  --repo "$protocol_repo" \
  --format json)
grep -Fq \
  '"data":[{"kind":"created","status":"open"},{"kind":"updated","status":"closed"}]' \
  <<<"$chained_projection"

chained_current=$("$binary" project \
  --definition "$chained_definition" \
  --projection current \
  --repo "$protocol_repo" \
  --format json)
grep -Fq '"data":[{"id":"item-1","status":"closed"}]' <<<"$chained_current"
grep -Fq \
  '"stats":{"records_scanned":2,"records_matched":1,"records_emitted":1}' \
  <<<"$chained_current"

chained_current_warm=$("$binary" project \
  --definition "$chained_definition" \
  --projection current \
  --repo "$protocol_repo" \
  --format json)
grep -Fq '"data":[{"id":"item-1","status":"closed"}]' <<<"$chained_current_warm"
grep -Fq '"cache_hit":true' <<<"$chained_current_warm"

chained_doctor=$("$binary" doctor \
  --definition "$chained_definition" \
  --repo "$protocol_repo" \
  --format json)
grep -Fq '"healthy":true' <<<"$chained_doctor"
grep -Fq '"binding_rows":2' <<<"$chained_doctor"

mkdir -p "$protocol_bind_repo/.ledger/example"
cp \
  "$chained_existing" \
  "$protocol_bind_repo/.ledger/example/chained-events.jsonl"
cp \
  "$protocol_bind_repo/.ledger/example/chained-events.jsonl" \
  "$protocol_bind_repo/chained-events.before"

chained_binding=$("$binary" transact \
  --definition "$chained_definition" \
  --operation bind-existing \
  --repo "$protocol_bind_repo" \
  --format json)
grep -Fq '"result":"bound"' <<<"$chained_binding"
grep -Fq '"storage_mutated":true' <<<"$chained_binding"
cmp -s \
  "$protocol_bind_repo/chained-events.before" \
  "$protocol_bind_repo/.ledger/example/chained-events.jsonl"

chained_bound_doctor=$("$binary" doctor \
  --definition "$chained_definition" \
  --repo "$protocol_bind_repo" \
  --format json)
grep -Fq '"healthy":true' <<<"$chained_bound_doctor"
grep -Fq '"binding_rows":1' <<<"$chained_bound_doctor"

mkdir -p "$protocol_bind_invalid_repo/.ledger/example"
cp \
  "$chained_existing_invalid" \
  "$protocol_bind_invalid_repo/.ledger/example/chained-events.jsonl"
set +e
chained_bind_failure=$("$binary" transact \
  --definition "$chained_definition" \
  --operation bind-existing \
  --repo "$protocol_bind_invalid_repo" \
  --format json)
chained_bind_failure_status=$?
set -e
test "$chained_bind_failure_status" -eq 2
grep -Fq '"code":"EventSequenceMismatch"' <<<"$chained_bind_failure"
test ! -d "$protocol_bind_invalid_repo/.ledger/.bindings" ||
  test -z "$(find "$protocol_bind_invalid_repo/.ledger/.bindings" -type f -print -quit)"

printf '%s\n' '{"kind":"one","value":9}' >"$repo_dir/.ledger/example/events.jsonl"
set +e
tamper_output=$("$binary" doctor \
  --definition "$event_definition" \
  --repo "$repo_dir" \
  --format json)
tamper_status=$?
set -e
test "$tamper_status" -eq 2
grep -Fq '"healthy":false' <<<"$tamper_output"
grep -Fq '"error_code":"StoreBindingRevisionMismatch"' <<<"$tamper_output"

mkdir -p "$legacy_repo/.ledger/example"
printf '%s\n' \
  '{"kind":"one","value":1}' \
  '{"kind":"two","value":2}' \
  >"$legacy_repo/.ledger/example/events.jsonl"
cp "$legacy_repo/.ledger/example/events.jsonl" "$legacy_repo/events.before"

binding_output=$("$binary" transact \
  --definition "$event_definition" \
  --operation bind-existing \
  --repo "$legacy_repo" \
  --format json)
grep -Fq '"schema":"ledger-transaction-result/v1"' <<<"$binding_output"
grep -Fq '"result":"bound"' <<<"$binding_output"
grep -Fq '"storage_mutated":true' <<<"$binding_output"
cmp -s \
  "$legacy_repo/events.before" \
  "$legacy_repo/.ledger/example/events.jsonl"

bound_projection=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$legacy_repo" \
  --format json)
grep -Fq \
  '"data":[{"kind":"one","value":1},{"kind":"two","value":2}]' \
  <<<"$bound_projection"

bound_doctor=$("$binary" doctor \
  --definition "$event_definition" \
  --repo "$legacy_repo" \
  --format json)
grep -Fq '"healthy":true' <<<"$bound_doctor"
grep -Fq '"binding_rows":1' <<<"$bound_doctor"

bound_append=$("$binary" transact \
  --definition "$event_definition" \
  --operation append \
  --repo "$legacy_repo" \
  --input "event=$event_input" \
  --param request=bound-append \
  --format json)
grep -Fq '"result":"appended"' <<<"$bound_append"

mixed_projection=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$legacy_repo" \
  --format json)
grep -Fq \
  '"data":[{"kind":"one","value":1},{"kind":"two","value":2},{"kind":"one","value":1}]' \
  <<<"$mixed_projection"
mixed_doctor=$("$binary" doctor \
  --definition "$event_definition" \
  --repo "$legacy_repo" \
  --format json)
grep -Fq '"healthy":true' <<<"$mixed_doctor"
grep -Fq '"binding_rows":2' <<<"$mixed_doctor"
cp "$legacy_repo/.ledger/example/events.jsonl" "$legacy_repo/events.after-append"
test ! -d "$repo_dir/.ledger/.revisions" ||
  test -z "$(find "$repo_dir/.ledger/.revisions" -type f -print -quit)"

snapshot_create=$("$binary" transact \
  --definition "$event_snapshot_definition" \
  --operation create \
  --repo "$repo_dir" \
  --input "snapshot=$event_snapshot_initial" \
  --param stream=snapshot-one \
  --format json)
grep -Fq '"result":"created"' <<<"$snapshot_create"
test -f "$repo_dir/.ledger/example/snapshot-one/snapshots.jsonl"

snapshot_replace=$("$binary" transact \
  --definition "$event_snapshot_definition" \
  --operation replace \
  --repo "$repo_dir" \
  --input "snapshot=$event_snapshot_replacement" \
  --param request=snapshot-replace \
  --param stream=snapshot-one \
  --format json)
grep -Fq '"result":"replaced"' <<<"$snapshot_replace"
compgen -G "$repo_dir/.ledger/.revisions/*.bin" >/dev/null

snapshot_duplicate=$("$binary" transact \
  --definition "$event_snapshot_definition" \
  --operation replace \
  --repo "$repo_dir" \
  --input "snapshot=$event_snapshot_replacement" \
  --param request=snapshot-replace \
  --param stream=snapshot-one \
  --format json)
grep -Fq '"result":"idempotent"' <<<"$snapshot_duplicate"
grep -Fq '"storage_mutated":false' <<<"$snapshot_duplicate"

snapshot_projection=$("$binary" project \
  --definition "$event_snapshot_definition" \
  --projection all \
  --repo "$repo_dir" \
  --param stream=snapshot-one \
  --format json)
grep -Fq '"data":[{"kind":"three","value":3}]' \
  <<<"$snapshot_projection"

snapshot_doctor=$("$binary" doctor \
  --definition "$event_snapshot_definition" \
  --repo "$repo_dir" \
  --param stream=snapshot-one \
  --format json)
grep -Fq '"healthy":true' <<<"$snapshot_doctor"
grep -Fq '"binding_rows":2' <<<"$snapshot_doctor"

set +e
duplicate_binding=$("$binary" transact \
  --definition "$event_definition" \
  --operation bind-existing \
  --repo "$legacy_repo" \
  --format json)
duplicate_binding_status=$?
set -e
test "$duplicate_binding_status" -eq 2
grep -Fq '"code":"StoreAlreadyBound"' <<<"$duplicate_binding"
cmp -s \
  "$legacy_repo/events.after-append" \
  "$legacy_repo/.ledger/example/events.jsonl"

mkdir -p "$invalid_repo/.ledger/example"
printf '%s\n' '{"kind":"one","value":1}' \
  >"$invalid_repo/.ledger/example/events.jsonl"
set +e
ignored_input_binding=$("$binary" transact \
  --definition "$event_definition" \
  --operation bind-existing \
  --repo "$invalid_repo" \
  --input "event=$event_input" \
  --format json)
ignored_input_binding_status=$?
set -e
test "$ignored_input_binding_status" -eq 2
grep -Fq \
  '"code":"BindingOperationRejectsExternalInput"' \
  <<<"$ignored_input_binding"
test ! -d "$invalid_repo/.ledger/.bindings" ||
  test -z "$(find "$invalid_repo/.ledger/.bindings" -type f -print -quit)"
test ! -d "$invalid_repo/.ledger/.definitions" ||
  test -z "$(find "$invalid_repo/.ledger/.definitions" -type f -print -quit)"

printf '%s\n' '{"kind":"invalid"}' \
  >"$invalid_repo/.ledger/example/events.jsonl"
cp "$invalid_repo/.ledger/example/events.jsonl" "$invalid_repo/events.before"
set +e
invalid_binding=$("$binary" transact \
  --definition "$event_definition" \
  --operation bind-existing \
  --repo "$invalid_repo" \
  --format json)
invalid_binding_status=$?
set -e
test "$invalid_binding_status" -eq 2
grep -Fq '"code":"ExistingStoreValidationFailed"' <<<"$invalid_binding"
cmp -s \
  "$invalid_repo/events.before" \
  "$invalid_repo/.ledger/example/events.jsonl"
test -z "$(find "$invalid_repo/.ledger/.bindings" -type f -print -quit)"
test -z "$(find "$invalid_repo/.ledger/.definitions" -type f -print -quit)"
