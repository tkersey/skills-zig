#!/usr/bin/env bash
set -euo pipefail

binary=$1
preparation_probe=${2:?preparation interruption probe binary is required}
test -x "$preparation_probe"
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

preparation_help=$("$binary" --help)
grep -Fq 'ledger prepare' <<<"$preparation_help"
grep -Fq 'ledger maintain' <<<"$preparation_help"
grep -Fiq 'inspect by default' <<<"$preparation_help"
test "$("$binary" prepare --help)" = "$preparation_help"
test "$("$binary" maintain --help)" = "$preparation_help"

capabilities=$("$binary" capabilities --format json)
grep -Fq '"schema":"ledger-capabilities/v1"' <<<"$capabilities"
grep -Fq '"id":"exact-object","version":2' <<<"$capabilities"
grep -Fq '"id":"optional-field","version":2' <<<"$capabilities"
grep -Fq '"id":"implies","version":5' <<<"$capabilities"
grep -Fq '"id":"regex","version":3' <<<"$capabilities"
grep -Fq '"id":"sha256","version":5' <<<"$capabilities"
grep -Fq '"id":"sorted","version":2' <<<"$capabilities"
grep -Fq '"id":"exactly-one","version":3' <<<"$capabilities"
grep -Fq '"id":"at-least-one","version":3' <<<"$capabilities"
grep -Fq '"id":"keyed-unique","version":2' <<<"$capabilities"
grep -Fq '"id":"keyed-join","version":1' <<<"$capabilities"
grep -Fq '"id":"reference-exists","version":9' <<<"$capabilities"
grep -Fq '"id":"predecessor-successor","version":1' <<<"$capabilities"
grep -Fq '"id":"declared-field-values","version":1' <<<"$capabilities"
grep -Fq '"id":"field-absent","version":1' <<<"$capabilities"
grep -Fq '"id":"object-values","version":1' <<<"$capabilities"
grep -Fq '"id":"total-partition","version":1' <<<"$capabilities"
grep -Fq '"id":"total-mapping","version":1' <<<"$capabilities"
grep -Fq '"id":"all","version":1' <<<"$capabilities"
grep -Fq '"id":"any","version":1' <<<"$capabilities"
grep -Fq '"id":"none","version":1' <<<"$capabilities"
grep -Fq '"id":"composite-identity","version":1' <<<"$capabilities"
grep -Fq '"id":"content-address","version":1' <<<"$capabilities"
grep -Fq '"id":"reducer","version":6' <<<"$capabilities"
grep -Fq '"id":"event-envelope","version":4' <<<"$capabilities"
grep -Fq '"id":"cross-input-equal","version":2' <<<"$capabilities"
grep -Fq '"id":"compare-and-append","version":2' <<<"$capabilities"
grep -Fq '"id":"bind-existing","version":2' <<<"$capabilities"
grep -Fq '"id":"rebind-existing","version":1' <<<"$capabilities"
grep -Fq '"id":"fold","version":7' <<<"$capabilities"
grep -Fq '"id":"relevance","version":3' <<<"$capabilities"
grep -Fq '"id":"tagged-union","version":1' <<<"$capabilities"
grep -Fq '"id":"text-render","version":1' <<<"$capabilities"
grep -Fq '"id":"timestamp-ordinal","version":1' <<<"$capabilities"
if grep -Eq \
  'actuat|universal|learnings|negative-ledger|synesthesia|SKDC|SDR|EPG' \
  <<<"$capabilities"
then
  exit 1
fi
if "$binary" capture --help >/dev/null 2>&1; then
  exit 1
fi
if "$binary" definition capture --help >/dev/null 2>&1; then
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
test "$projection_payload" = '{"kind":"one","value":1}'

projection_jsonl=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$repo_dir" \
  --format jsonl)
test "$projection_jsonl" = '{"kind":"one","value":1}'

projection_table=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$repo_dir" \
  --format table)
grep -Fq $'kind\tvalue' <<<"$projection_table"
grep -Fq $'one\t1' <<<"$projection_table"

projection_markdown=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$repo_dir" \
  --format markdown)
grep -Fq '| kind | value |' <<<"$projection_markdown"
grep -Fq '| one | 1 |' <<<"$projection_markdown"

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
grep -Fq '"storage_mutated":true' <<<"$idempotent_output"

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
grep -Fq '"storage_mutated":false' <<<"$conflict_output"
grep -Fq '"storage_mutation_state":"known"' <<<"$conflict_output"

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
grep -Fq '"storage_mutated":true' <<<"$chained_duplicate"

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
  '"stats":{"records_scanned":2,"records_matched":1,"records_emitted":1,"streamed":false}' \
  <<<"$chained_current"

chained_current_warm=$("$binary" project \
  --definition "$chained_definition" \
  --projection current \
  --repo "$protocol_repo" \
  --format json)
grep -Fq '"data":[{"id":"item-1","status":"closed"}]' <<<"$chained_current_warm"
grep -Fq '"cache_hit":true' <<<"$chained_current_warm"

# Chained protocols own their envelope kind; their reducer deliberately has no
# event_kind selector. Source-order ranking must not require that plain-only field.
chained_ordered=$("$binary" project \
  --definition "$chained_definition" \
  --projection ordered-current \
  --repo "$protocol_repo" \
  --format json)
grep -Fq '"data":[{"id":"item-1","status":"closed"}]' <<<"$chained_ordered"

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

cp "$repo_dir/.ledger/example/events.jsonl" "$repo_dir/events.before-rebind"
rebind_output=$("$binary" transact \
  --definition "$event_definition" \
  --operation rebind-existing \
  --repo "$repo_dir" \
  --format json)
grep -Fq '"result":"rebound"' <<<"$rebind_output"
grep -Fq '"storage_mutated":true' <<<"$rebind_output"
cmp -s \
  "$repo_dir/events.before-rebind" \
  "$repo_dir/.ledger/example/events.jsonl"

rebound_doctor=$("$binary" doctor \
  --definition "$event_definition" \
  --repo "$repo_dir" \
  --format json)
grep -Fq '"healthy":true' <<<"$rebound_doctor"
grep -Fq '"binding_rows":1' <<<"$rebound_doctor"

rebound_projection=$("$binary" project \
  --definition "$event_definition" \
  --projection all \
  --repo "$repo_dir" \
  --format json)
grep -Fq '"data":[{"kind":"one","value":9}]' <<<"$rebound_projection"

printf '%s\n' '{"kind":"invalid"}' \
  >"$repo_dir/.ledger/example/events.jsonl"
cp "$repo_dir/.ledger/example/events.jsonl" "$repo_dir/events.invalid"
set +e
invalid_rebind_output=$("$binary" transact \
  --definition "$event_definition" \
  --operation rebind-existing \
  --repo "$repo_dir" \
  --format json)
invalid_rebind_status=$?
set -e
test "$invalid_rebind_status" -eq 2
grep -Fq '"code":"ExistingStoreValidationFailed"' \
  <<<"$invalid_rebind_output"
grep -Fq '"storage_mutation_state":"known"' <<<"$invalid_rebind_output"
cmp -s \
  "$repo_dir/events.invalid" \
  "$repo_dir/.ledger/example/events.jsonl"

cp "$repo_dir/events.before-rebind" \
  "$repo_dir/.ledger/example/events.jsonl"
restored_doctor=$("$binary" doctor \
  --definition "$event_definition" \
  --repo "$repo_dir" \
  --format json)
grep -Fq '"healthy":true' <<<"$restored_doctor"

set +e
duplicate_rebind=$("$binary" transact \
  --definition "$event_definition" \
  --operation rebind-existing \
  --repo "$repo_dir" \
  --format json)
duplicate_rebind_status=$?
set -e
test "$duplicate_rebind_status" -eq 2
grep -Fq '"code":"StoreAlreadyBound"' <<<"$duplicate_rebind"

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
grep -Fq '"storage_mutated":true' <<<"$snapshot_duplicate"

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

# Exercise relational admission and derived folds through the real CLI.
bash scripts/test-ledger-relations.sh "$binary"

# A derived identity must survive the actual archive/replay path. A source
# ordering that cannot be reconstructed must fail before changing the store.
derived_definition=apps/ledger/src/v1/fixtures/derived-layout-definition.json
derived_repo="$repo_dir/derived-layout"
mkdir -p "$derived_repo"
printf '%s\n' '{"record":{"subject":{"a":1,"b":2,"c":3}}}' >"$repo_dir/derived-input.json"
"$binary" transact --definition "$derived_definition" --operation capture \
  --repo "$derived_repo" --input "submission=$repo_dir/derived-input.json" \
  --format json >"$repo_dir/derived-capture.json"
derived_fingerprint=e6a3385fb77c287a712e7f406a451727f0625041823ecf23bea7ef39b2e39805
grep -Fq "$derived_fingerprint" "$repo_dir/derived-capture.json"
"$binary" project --definition "$derived_definition" --projection records \
  --repo "$derived_repo" --format json >"$repo_dir/derived-projection.json"
grep -Fq "$derived_fingerprint" "$repo_dir/derived-projection.json"
"$binary" doctor --definition "$derived_definition" --repo "$derived_repo" \
  --format json >"$repo_dir/derived-before.json"
grep -Fq '"healthy":true' "$repo_dir/derived-before.json"
grep -Fq '"binding_rows":1' "$repo_dir/derived-before.json"
printf '%s\n' '{"record":{"subject":{"b":2,"a":1,"c":3}}}' >"$repo_dir/derived-input.json"
set +e
"$binary" transact --definition "$derived_definition" --operation capture \
  --repo "$derived_repo" --input "submission=$repo_dir/derived-input.json" \
  --format json >"$repo_dir/derived-rejected.json"
derived_status=$?
set -e
test "$derived_status" -eq 2
grep -Fq '"code":"EventDerivedValueMismatch"' "$repo_dir/derived-rejected.json"
"$binary" doctor --definition "$derived_definition" --repo "$derived_repo" \
  --format json >"$repo_dir/derived-after.json"
# Cache timing is not part of store health; compare the complete slot report.
json_cli=$(command -v jaq || command -v jq)
"$json_cli" -S '.slots' "$repo_dir/derived-before.json" >"$repo_dir/derived-slots-before.json"
"$json_cli" -S '.slots' "$repo_dir/derived-after.json" >"$repo_dir/derived-slots-after.json"
cmp -s "$repo_dir/derived-slots-before.json" "$repo_dir/derived-slots-after.json"

preparation_dir="$repo_dir/preparation"
preparation_source="$preparation_dir/source"
preparation_target="$preparation_dir/target"
preparation_prefix="$preparation_dir/prefix"
preparation_empty="$preparation_dir/empty"
preparation_divergent="$preparation_dir/divergent"
preparation_conflict="$preparation_dir/conflict"
preparation_archive="$preparation_dir/legacy-archive/fixture/worktree-0"
preparation_archive_target="$preparation_dir/archive-target"
mkdir -p "$preparation_dir" "$preparation_source" "$preparation_divergent"
trap 'status=$?; printf "preparation smoke failure at line %s (exit %s)\n" "$LINENO" "$status" >&2; for result in "$preparation_dir"/*.json; do test ! -f "$result" || { printf "%s\n" "$result" >&2; cat "$result" >&2; }; done; exit "$status"' ERR

preparation_init() {
  mkdir -p "$1/.ledger"
  printf '%s\n' '{"schema":"ledger-storage-root/v1","store_id":"preparation-smoke"}' >"$1/.ledger-root.json"
}

preparation_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

preparation_fingerprint() {
  (
    cd "$1"
    find . -print | LC_ALL=C sort
    while IFS= read -r path; do
      printf '%s %s\n' "$(preparation_hash "$path")" "$path"
    done < <(find . -type f -print | LC_ALL=C sort)
  )
}

preparation_expect_failure() {
  local expected=$1
  local output=$2
  shift 2
  local status=0
  "$binary" "$@" >"$output" || status=$?
  test "$status" -eq 2
  "$json_cli" -e --arg expected "$expected" \
    '.code == $expected or .outcome == $expected' "$output" >/dev/null
}

for preparation_root in "$preparation_target" "$preparation_prefix" "$preparation_empty" "$preparation_conflict" "$preparation_archive_target"; do
  preparation_init "$preparation_root"
done
"$binary" transact --definition "$event_definition" --operation append \
  --repo "$preparation_source" --input "event=$event_input" --param request=prepare-one \
  --format json >"$preparation_dir/source-one.json"
"$binary" transact --definition "$event_definition" --operation append \
  --store-root "$preparation_prefix" --store-id preparation-smoke \
  --input "event=$event_input" --param request=prepare-one \
  --format json >"$preparation_dir/prefix-one.json"
"$binary" transact --definition "$event_definition" --operation append \
  --repo "$preparation_source" --input "event=$event_two" --param request=prepare-two \
  --format json >"$preparation_dir/source-two.json"
printf '%s\n' '{"kind":"one","value":1}' '{"kind":"two","value":2}' >"$preparation_dir/expected.jsonl"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_source/.ledger/example/events.jsonl"
mkdir -p "$preparation_source/.ledger/unrelated-cas"
dd if=/dev/zero of="$preparation_source/.ledger/unrelated-cas/oversized.bin" bs=1 count=0 seek=2147483649 2>/dev/null
test "$(wc -c <"$preparation_source/.ledger/unrelated-cas/oversized.bin")" -gt 2147483648

preparation_fingerprint "$preparation_target" >"$preparation_dir/inspect-before"
"$binary" prepare --definition "$event_definition" \
  --store-root "$preparation_target" --store-id preparation-smoke \
  --source-root "$preparation_source" --format json >"$preparation_dir/inspect.json"
"$json_cli" -e '.outcome == "ready" and .records == 2 and .storage_mutated == false and .selected_bytes < 1048576 and .bytes_read < 1048576' \
  "$preparation_dir/inspect.json" >/dev/null
"$binary" maintain --store-root "$preparation_target" --store-id preparation-smoke \
  --format json >"$preparation_dir/maintain-inspect.json"
"$json_cli" -e '.outcome == "healthy" and .phase == "inspection" and .storage_mutated == false' \
  "$preparation_dir/maintain-inspect.json" >/dev/null
preparation_fingerprint "$preparation_target" >"$preparation_dir/inspect-after"
cmp -s "$preparation_dir/inspect-before" "$preparation_dir/inspect-after"
test ! -e "$preparation_target/.ledger/.preparation"

"$binary" prepare --definition "$event_definition" \
  --store-root "$preparation_target" --store-id preparation-smoke \
  --source-root "$preparation_source" --apply --format json >"$preparation_dir/applied.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2 and .phase == "committed" and .selected_bytes < 1048576 and .bytes_read < 1048576' \
  "$preparation_dir/applied.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_target/.ledger/example/events.jsonl"
test ! -e "$preparation_target/.ledger/unrelated-cas"
test -z "$(find "$preparation_target/.ledger/.preparation" -name 'payload-*' -print -quit)"
"$binary" project --definition "$event_definition" --projection all \
  --store-root "$preparation_target" --store-id preparation-smoke \
  --format jsonl >"$preparation_dir/projection.jsonl"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_dir/projection.jsonl"

preparation_fingerprint "$preparation_prefix" >"$preparation_dir/prefix-before"
preparation_expect_failure reconciliation-required "$preparation_dir/prefix-inspect.json" \
  prepare --definition "$event_definition" --store-root "$preparation_prefix" \
  --store-id preparation-smoke --source-root "$preparation_source" --format json
preparation_fingerprint "$preparation_prefix" >"$preparation_dir/prefix-after"
cmp -s "$preparation_dir/prefix-before" "$preparation_dir/prefix-after"
cp "$preparation_prefix/.ledger/example/events.jsonl" "$preparation_dir/prefix-events-before"
preparation_expect_failure reconciliation-required "$preparation_dir/prefix-apply.json" \
  prepare --definition "$event_definition" --store-root "$preparation_prefix" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply --format json
cmp -s "$preparation_dir/prefix-events-before" "$preparation_prefix/.ledger/example/events.jsonl"
test ! -e "$preparation_prefix/.ledger/.preparation"

preparation_binding=$(find "$preparation_target/.ledger/.bindings" -name '*.jsonl' -type f -print -quit)
test -n "$preparation_binding"
cp "$preparation_binding" "$preparation_dir/binding-before"
rm "$preparation_target/.ledger/example/events.jsonl"
"$binary" prepare --definition "$event_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply \
  --format json >"$preparation_dir/restored.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2' "$preparation_dir/restored.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_target/.ledger/example/events.jsonl"
cmp -s "$preparation_dir/binding-before" "$preparation_binding"

preparation_capture_retries="$preparation_dir/interrupted-capture-retries"
preparation_init "$preparation_capture_retries"
cp "$preparation_capture_retries/.ledger-root.json" "$preparation_dir/capture-retries-marker.json"
preparation_selected_bytes=$("$json_cli" -r '.selected_bytes' "$preparation_dir/inspect.json")
preparation_capture_files=0
for ((preparation_retry=0; preparation_retry<100; preparation_retry++)); do
  preparation_fault_status=0
  LEDGER_PREPARATION_FAULT=capture "$preparation_probe" prepare \
    --definition "$event_definition" --store-root "$preparation_capture_retries" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/capture-failure-latest.json" || preparation_fault_status=$?
  test "$preparation_fault_status" -eq 99
  preparation_capture_record="$preparation_capture_retries/.ledger/.preparation/operation.json"
  "$json_cli" -e '.phase == "capturing" and .installed == false and (.files | length) > 0' \
    "$preparation_capture_record" >/dev/null
  preparation_current_files=$("$json_cli" -r '.files | length' "$preparation_capture_record")
  if test "$preparation_retry" -eq 0; then preparation_capture_files=$preparation_current_files; fi
  test "$preparation_current_files" -eq "$preparation_capture_files"
  preparation_work_files=$(find "$preparation_capture_retries/.ledger/.preparation" -type f -print | wc -l)
  test "$preparation_work_files" -le "$((preparation_capture_files + 2))"
  preparation_work_bytes=$(find "$preparation_capture_retries/.ledger/.preparation" -type f -exec wc -c {} \; | awk '{sum += $1} END {print sum + 0}')
  test "$preparation_work_bytes" -le "$((preparation_selected_bytes + 1048576))"
  test -s "$preparation_capture_retries/.ledger/.preparation/payload-0"
  test ! -e "$preparation_capture_retries/.ledger/example/events.jsonl"
  test -z "$(find "$preparation_capture_retries/.ledger/.transactions" -name transaction.json -o -name commit.json)"
  test -z "$(find "$preparation_capture_retries" -type d -name '*archive*' -print -quit)"
  test "$(find "$preparation_capture_retries/.ledger" -maxdepth 1 -type d -name '.preparation*' -print | wc -l)" -eq 1
  cmp -s "$preparation_dir/capture-retries-marker.json" "$preparation_capture_retries/.ledger-root.json"
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_source/.ledger/example/events.jsonl"
done
"$binary" prepare --definition "$event_definition" --store-root "$preparation_capture_retries" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/capture-retries-recovered.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2' "$preparation_dir/capture-retries-recovered.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_capture_retries/.ledger/example/events.jsonl"
cmp -s "$preparation_dir/capture-retries-marker.json" "$preparation_capture_retries/.ledger-root.json"
test -z "$(find "$preparation_capture_retries/.ledger/.preparation" -name 'payload-*' -print -quit)"

preparation_cleanup_retries="$preparation_dir/committed-cleanup-retries"
preparation_init "$preparation_cleanup_retries"
cp "$preparation_cleanup_retries/.ledger-root.json" "$preparation_dir/cleanup-retries-marker.json"
preparation_fault_status=0
LEDGER_PREPARATION_FAULT=cleanup "$preparation_probe" prepare \
  --definition "$event_definition" --store-root "$preparation_cleanup_retries" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/cleanup-first-commit.json" || preparation_fault_status=$?
test "$preparation_fault_status" -eq 2
"$json_cli" -e '.outcome == "committed-with-later-failure" and .phase == "cleanup" and .transaction_id != null' \
  "$preparation_dir/cleanup-first-commit.json" >/dev/null
for ((preparation_retry=0; preparation_retry<100; preparation_retry++)); do
  "$json_cli" -e '.phase == "installed" and .installed == true' \
    "$preparation_cleanup_retries/.ledger/.preparation/operation.json" >/dev/null
  preparation_fault_status=0
  LEDGER_PREPARATION_FAULT=cleanup "$preparation_probe" prepare \
    --definition "$event_definition" --store-root "$preparation_cleanup_retries" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/cleanup-failure-latest.json" || preparation_fault_status=$?
  test "$preparation_fault_status" -eq 2
  "$json_cli" -e '.code == "AccessDenied"' "$preparation_dir/cleanup-failure-latest.json" >/dev/null
  preparation_fingerprint "$preparation_cleanup_retries/.ledger/.transactions" >"$preparation_dir/cleanup-journals-latest"
  if test "$preparation_retry" -eq 0; then
    cp "$preparation_dir/cleanup-journals-latest" "$preparation_dir/cleanup-journals-first"
  else
    cmp -s "$preparation_dir/cleanup-journals-first" "$preparation_dir/cleanup-journals-latest"
  fi
  preparation_work_bytes=$(find "$preparation_cleanup_retries/.ledger/.preparation" -type f -exec wc -c {} \; | awk '{sum += $1} END {print sum + 0}')
  test "$preparation_work_bytes" -le "$((preparation_selected_bytes + 1048576))"
  test -z "$(find "$preparation_cleanup_retries" -type d -name '*archive*' -print -quit)"
  cmp -s "$preparation_dir/cleanup-retries-marker.json" "$preparation_cleanup_retries/.ledger-root.json"
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_cleanup_retries/.ledger/example/events.jsonl"
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_source/.ledger/example/events.jsonl"
done
"$binary" prepare --definition "$event_definition" --store-root "$preparation_cleanup_retries" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/cleanup-retries-recovered.json"
"$json_cli" -e '.outcome == "covered" and .records == 2 and .staged_bytes == 0 and .transaction_id == null' \
  "$preparation_dir/cleanup-retries-recovered.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_cleanup_retries/.ledger/example/events.jsonl"
test -z "$(find "$preparation_cleanup_retries/.ledger/.preparation" -name 'payload-*' -print -quit)"

for preparation_fault in capture publication verification cleanup; do
  preparation_fault_root="$preparation_dir/fault-$preparation_fault"
  preparation_init "$preparation_fault_root"
  cp "$preparation_fault_root/.ledger-root.json" "$preparation_dir/fault-marker-before.json"
  preparation_fault_status=0
  LEDGER_PREPARATION_FAULT="$preparation_fault" "$preparation_probe" prepare \
    --definition "$event_definition" --store-root "$preparation_fault_root" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/fault-$preparation_fault.json" || preparation_fault_status=$?
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_source/.ledger/example/events.jsonl"
  test -s "$preparation_fault_root/.ledger/.preparation/payload-0"
  if test "$preparation_fault" = capture; then
    test "$preparation_fault_status" -eq 99
    "$json_cli" -e '.phase == "capturing" and .installed == false' \
      "$preparation_fault_root/.ledger/.preparation/operation.json" >/dev/null
    test ! -e "$preparation_fault_root/.ledger/example/events.jsonl"
    test -z "$(find "$preparation_fault_root/.ledger/.transactions" -name transaction.json -print -quit)"
  elif test "$preparation_fault" = publication; then
    test "$preparation_fault_status" -eq 99
    "$json_cli" -e '.phase == "installed" and .installed == true' \
      "$preparation_fault_root/.ledger/.preparation/operation.json" >/dev/null
    test ! -e "$preparation_fault_root/.ledger/example/events.jsonl"
    preparation_fault_journal=$(find "$preparation_fault_root/.ledger/.transactions" -name transaction.json -print -quit)
    test -n "$preparation_fault_journal"
    "$json_cli" -e '.state == "prepared"' "$preparation_fault_journal" >/dev/null
    preparation_fingerprint "$preparation_fault_root" >"$preparation_dir/publication-blocked-before"
    preparation_expect_failure recovery-required "$preparation_dir/publication-inspect.json" \
      prepare --definition "$event_definition" --store-root "$preparation_fault_root" \
      --store-id preparation-smoke --source-root "$preparation_source" --format json
    preparation_maintenance_status=0
    "$binary" maintain --store-root "$preparation_fault_root" --store-id preparation-smoke \
      --apply --format json >"$preparation_dir/publication-maintain.json" || preparation_maintenance_status=$?
    test "$preparation_maintenance_status" -eq 2
    "$json_cli" -e '.outcome == "blocked" and .error_code == "TransactionRecoveryRequired"' \
      "$preparation_dir/publication-maintain.json" >/dev/null
    preparation_fingerprint "$preparation_fault_root" >"$preparation_dir/publication-blocked-after"
    cmp -s "$preparation_dir/publication-blocked-before" "$preparation_dir/publication-blocked-after"
  else
    test "$preparation_fault_status" -eq 2
    "$json_cli" -e --arg phase "$preparation_fault" \
      '.outcome == "committed-with-later-failure" and .phase == $phase and .transaction_id != null' \
      "$preparation_dir/fault-$preparation_fault.json" >/dev/null
    cmp -s "$preparation_dir/expected.jsonl" "$preparation_fault_root/.ledger/example/events.jsonl"
    preparation_fault_journal=$(find "$preparation_fault_root/.ledger/.transactions" -name transaction.json -print -quit)
    test -n "$preparation_fault_journal"
    "$json_cli" -e '.state == "committed"' "$preparation_fault_journal" >/dev/null
    test -f "$(dirname "$preparation_fault_journal")/commit.json"
  fi
  "$binary" prepare --definition "$event_definition" --store-root "$preparation_fault_root" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/fault-$preparation_fault-retry.json"
  if test "$preparation_fault" = capture; then
    "$json_cli" -e '.outcome == "prepared" and .records == 2' \
      "$preparation_dir/fault-$preparation_fault-retry.json" >/dev/null
  else
    "$json_cli" -e '.outcome == "covered" and .records == 2 and .staged_bytes == 0 and .transaction_id == null' \
      "$preparation_dir/fault-$preparation_fault-retry.json" >/dev/null
  fi
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_fault_root/.ledger/example/events.jsonl"
  cmp -s "$preparation_dir/fault-marker-before.json" "$preparation_fault_root/.ledger-root.json"
  test -z "$(find "$preparation_fault_root/.ledger/.preparation" -name 'payload-*' -print -quit)"
  "$json_cli" -e '.phase == "finalized" and .installed == true' \
    "$preparation_fault_root/.ledger/.preparation/operation.json" >/dev/null
  "$binary" project --definition "$event_definition" --projection all \
    --store-root "$preparation_fault_root" --store-id preparation-smoke --format jsonl \
    >"$preparation_dir/fault-$preparation_fault-projection.jsonl"
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_dir/fault-$preparation_fault-projection.jsonl"
done

cp -R "$preparation_source/.ledger/.bindings" "$preparation_source/.ledger/.definitions" "$preparation_conflict/.ledger/"
preparation_conflicting_binding=$(find "$preparation_conflict/.ledger/.bindings" -name '*.jsonl' -type f -print -quit)
sed 's/prepare-two/conflicting-request/g' "$preparation_conflicting_binding" >"$preparation_dir/conflicting-binding"
mv "$preparation_dir/conflicting-binding" "$preparation_conflicting_binding"
preparation_expect_failure PreparationBindingConflict "$preparation_dir/conflict.json" \
  prepare --definition "$event_definition" --store-root "$preparation_conflict" \
  --store-id preparation-smoke --source-root "$preparation_source" --format json
test ! -e "$preparation_conflict/.ledger/example/events.jsonl"

"$binary" transact --definition "$event_definition" --operation append \
  --repo "$preparation_divergent" --input "event=$event_two" --param request=divergent \
  --format json >"$preparation_dir/divergent-write.json"
preparation_fingerprint "$preparation_empty" >"$preparation_dir/divergence-before"
preparation_expect_failure PreparationDivergentHistory "$preparation_dir/divergent.json" \
  prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-root "$preparation_source" \
  --source-root "$preparation_divergent" --format json
preparation_fingerprint "$preparation_empty" >"$preparation_dir/divergence-after"
cmp -s "$preparation_dir/divergence-before" "$preparation_dir/divergence-after"

mkdir -p "$preparation_archive/.ledger"
cp -R "$preparation_source/.ledger/example" "$preparation_source/.ledger/.bindings" \
  "$preparation_source/.ledger/.definitions" "$preparation_archive/.ledger/"
: >"$preparation_dir/archive-entries.jsonl"
while IFS= read -r preparation_file; do
  preparation_relative=${preparation_file#"$preparation_archive/"}
  "$json_cli" -cn --arg key "$preparation_relative" \
    --arg sha256 "$(preparation_hash "$preparation_file")" \
    --argjson size "$(wc -c <"$preparation_file" | tr -d '[:space:]')" \
    '{key:$key,value:{kind:"file",sha256:$sha256,size:$size}}' >>"$preparation_dir/archive-entries.jsonl"
done < <(find "$preparation_archive/.ledger" -type f \( -name '*.jsonl' -o -name '*.json' \) -print)
"$json_cli" -s '{schema:"ledger-legacy-archive/v1",sources:{"0":{entries:from_entries}}}' \
  "$preparation_dir/archive-entries.jsonl" >"$preparation_dir/legacy-archive/fixture/manifest.json"
printf '%s\n' damaged >"$preparation_archive/.ledger/unrelated-evidence"
"$json_cli" '.sources["0"].entries[".ledger/unrelated-evidence"] = {kind:"file",size:100,sha256:"deliberately-mismatched"}' \
  "$preparation_dir/legacy-archive/fixture/manifest.json" >"$preparation_dir/manifest-updated.json"
mv "$preparation_dir/manifest-updated.json" "$preparation_dir/legacy-archive/fixture/manifest.json"
"$binary" prepare --definition "$event_definition" --store-root "$preparation_archive_target" \
  --store-id preparation-smoke --source-root "$preparation_source" \
  --source-archive "$preparation_archive" --apply --format json >"$preparation_dir/archive-applied.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2 and (.observations | length) == 2' \
  "$preparation_dir/archive-applied.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_archive_target/.ledger/example/events.jsonl"
test ! -e "$preparation_archive_target/.ledger/unrelated-evidence"
"$binary" project --definition "$event_definition" --projection all \
  --store-root "$preparation_archive_target" --store-id preparation-smoke \
  --format jsonl >"$preparation_dir/archive-projection.jsonl"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_dir/archive-projection.jsonl"

preparation_required=$(find "$preparation_archive/.ledger/.definitions" -name '*.json' -type f -print -quit)
cp "$preparation_required" "$preparation_dir/required-before.json"
printf '%s\n' '{}' >"$preparation_required"
preparation_status=0
"$binary" prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-archive "$preparation_archive" --format json \
  >"$preparation_dir/required-corrupt.json" || preparation_status=$?
test "$preparation_status" -eq 2
"$json_cli" -e '.schema == "ledger-transaction-error/v1" and .storage_mutated == false' \
  "$preparation_dir/required-corrupt.json" >/dev/null
test ! -e "$preparation_empty/.ledger/example/events.jsonl"
cp "$preparation_dir/required-before.json" "$preparation_required"
printf '%s\n' '{}' >"$preparation_dir/legacy-archive/fixture/manifest.json"
preparation_expect_failure MissingField "$preparation_dir/manifest-corrupt.json" \
  prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-archive "$preparation_archive" --format json

"$binary" prepare --definition "$event_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply \
  --format json >"$preparation_dir/covered-warm.json"
"$json_cli" -e '.outcome == "covered" and .staged_bytes == 0' "$preparation_dir/covered-warm.json" >/dev/null
preparation_fingerprint "$preparation_target/.ledger" >"$preparation_dir/retries-before"
for ((preparation_retry=0; preparation_retry<100; preparation_retry++)); do
  "$binary" prepare --definition "$event_definition" --store-root "$preparation_target" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply \
    --format json >"$preparation_dir/covered-latest.json"
  "$json_cli" -e '.outcome == "covered" and .staged_bytes == 0 and .records == 2' \
    "$preparation_dir/covered-latest.json" >/dev/null
done
preparation_fingerprint "$preparation_target/.ledger" >"$preparation_dir/retries-after"
cmp -s "$preparation_dir/retries-before" "$preparation_dir/retries-after"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_target/.ledger/example/events.jsonl"
cmp -s "$preparation_dir/binding-before" "$preparation_binding"
