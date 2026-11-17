#!/usr/bin/env bash
set -euo pipefail

binary=$1
bash scripts/test-ledger-gist.sh "$binary"
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
    '.code == $expected or .error_code == $expected or .outcome == $expected' "$output" >/dev/null
}

preparation_measurement_check() {
  "$json_cli" -e '
    .schema == "ledger-preparation-probe-measurements/v1" and
    .bytes_read > 0 and .samples > 1 and
    .target_bytes_written == (.positional_bytes_written + .streaming_bytes_written) and
    .peak_working_bytes >= (.initial.preparation_bytes + .initial.native_working_bytes) and
    .peak_working_bytes >= (.retained.preparation_bytes + .retained.native_working_bytes) and
    .peak_additional_working_bytes ==
      (.peak_working_bytes - .initial.preparation_bytes - .initial.native_working_bytes)
  ' "$1" >/dev/null
}

preparation_measurement_result() {
  preparation_measurement_check "$1"
  local invocation_bytes
  invocation_bytes=$(( $(wc -c <"$event_definition") + $(wc -c <"$preparation_target/.ledger-root.json") ))
  "$json_cli" -e --argjson invocation "$invocation_bytes" --slurpfile result "$2" '
    .bytes_read == ($result[0].bytes_read + $invocation) and
    .reclaimed_native_bytes == $result[0].reclaimed_bytes and
    .peak_working_bytes <= $result[0].estimated_peak_additional_bytes
  ' "$1" >/dev/null
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
preparation_budget_root="$preparation_dir/prejournal-budget"
preparation_budget_reset() {
  rm -rf "$preparation_budget_root"
  preparation_init "$preparation_budget_root"
  for metadata in .definitions .revisions; do
    if test -d "$preparation_source/.ledger/$metadata"; then
      cp -R "$preparation_source/.ledger/$metadata" "$preparation_budget_root/.ledger/"
    fi
  done
}
preparation_budget_run() {
  preparation_budget_status=0
  "$binary" prepare --definition "$event_definition" \
    --store-root "$preparation_budget_root" --store-id preparation-smoke \
    --source-root "$preparation_source" --apply "$@" --format json \
    >"$preparation_dir/prejournal-budget.json" || preparation_budget_status=$?
  test "$preparation_budget_status" -eq 0 || test "$preparation_budget_status" -eq 2
}
preparation_budget_reset
preparation_budget_run
test "$preparation_budget_status" -eq 0
preparation_budget_low=1
preparation_budget_high=$("$json_cli" -r '.bytes_read' "$preparation_dir/prejournal-budget.json")
while test "$preparation_budget_low" -lt "$preparation_budget_high"; do
  preparation_budget_mid=$(( (preparation_budget_low + preparation_budget_high) / 2 ))
  preparation_budget_reset
  preparation_budget_run --max-read-bytes "$preparation_budget_mid"
  case $("$json_cli" -r '.phase' "$preparation_dir/prejournal-budget.json") in
    publication|verification|cleanup|committed) preparation_budget_high=$preparation_budget_mid ;;
    *) preparation_budget_low=$(( preparation_budget_mid + 1 )) ;;
  esac
done
preparation_budget_reset
preparation_budget_run --max-read-bytes "$preparation_budget_low"
test "$preparation_budget_status" -eq 2
"$json_cli" -e '
  .phase == "publication" and .error_code == "ReadBudgetExceeded" and
  .outcome == "incomplete" and .transaction_id == null and .storage_mutated == true and
  .bytes_read <= .limits.max_read_bytes and .file_reads > 0 and .records == 2
' "$preparation_dir/prejournal-budget.json" >/dev/null
test -z "$(find "$preparation_budget_root/.ledger/.transactions" -name transaction.json -print)"
test ! -e "$preparation_budget_root/.ledger/example/events.jsonl"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_source/.ledger/example/events.jsonl"
preparation_budget_run
test "$preparation_budget_status" -eq 0
"$json_cli" -e '.outcome == "prepared" and .store_id == "preparation-smoke" and .records == 2' \
  "$preparation_dir/prejournal-budget.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_budget_root/.ledger/example/events.jsonl"
preparation_alias_target="$preparation_dir/alias-target"
preparation_init "$preparation_alias_target"
cp "$preparation_alias_target/.ledger-root.json" "$preparation_dir/alias-marker-before.json"
while IFS= read -r preparation_advisory; do
  preparation_relative=${preparation_advisory#"$preparation_source/.ledger/"}
  mkdir -p "$preparation_alias_target/.ledger/$(dirname "$preparation_relative")"
  cp "$preparation_advisory" "$preparation_alias_target/.ledger/$preparation_relative"
done < <(find "$preparation_source/.ledger/example" "$preparation_source/.ledger/.bindings" \
  -type f -name '*.cas.lock.advisory' -print)
preparation_fingerprint "$preparation_source" >"$preparation_dir/alias-source-before"
"$binary" prepare --definition "$event_definition" \
  --store-root "$preparation_alias_target" --store-id preparation-smoke \
  --source-store "preparation-smoke=$preparation_alias_target" \
  --source-store "preparation-smoke=$preparation_alias_target" \
  --source-store "preparation-smoke=$preparation_alias_target//" \
  --source-root "$preparation_source" --apply --format json >"$preparation_dir/alias-applied.json"
"$json_cli" -e --arg target "$preparation_alias_target" --arg source "$preparation_source" '
  .outcome == "prepared" and .records == 2 and .store_id == "preparation-smoke" and
  (.observations | length) == 4 and
  .observations[0].root == $target and .observations[1].root == $target and
  .observations[2].root == ($target + "//") and
  all(.observations[0:3][]; .revision == null and .records == 0 and .store_id == "preparation-smoke") and
  .observations[3].root == $source and .observations[3].records == 2
' "$preparation_dir/alias-applied.json" >/dev/null
"$json_cli" -e --slurpfile result "$preparation_dir/alias-applied.json" \
  '.provenance == $result[0].observations' "$preparation_alias_target/.ledger/.preparation.json" >/dev/null
cmp -s "$preparation_dir/alias-marker-before.json" "$preparation_alias_target/.ledger-root.json"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_alias_target/.ledger/example/events.jsonl"
preparation_fingerprint "$preparation_source" >"$preparation_dir/alias-source-after"
cmp -s "$preparation_dir/alias-source-before" "$preparation_dir/alias-source-after"
"$binary" project --definition "$event_definition" --projection all \
  --store-root "$preparation_alias_target" --store-id preparation-smoke \
  --format jsonl >"$preparation_dir/alias-projection.jsonl"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_dir/alias-projection.jsonl"
mkdir -p "$preparation_source/.ledger/unrelated-cas"
dd if=/dev/zero of="$preparation_source/.ledger/unrelated-cas/oversized.bin" bs=1 count=0 seek=2147483649 2>/dev/null
test "$(wc -c <"$preparation_source/.ledger/unrelated-cas/oversized.bin")" -gt 2147483648

preparation_fingerprint "$preparation_target" >"$preparation_dir/inspect-before"
preparation_expect_failure ReadBudgetExceeded "$preparation_dir/read-bound.json" \
  prepare --definition "$event_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply \
  --max-read-bytes 1 --format json
"$json_cli" -e '.outcome == "incomplete" and .storage_mutated == false and .bytes_read == 0 and .file_reads > 0 and .read_scope == "preparation-operation-including-native-recovery"' \
  "$preparation_dir/read-bound.json" >/dev/null
preparation_maintenance_status=0
"$binary" maintain --store-root "$preparation_target" --store-id preparation-smoke \
  --apply --max-read-bytes 1 --format json >"$preparation_dir/maintenance-read-bound.json" || preparation_maintenance_status=$?
test "$preparation_maintenance_status" -eq 2
"$json_cli" -e '.outcome == "incomplete" and .error_code == "ReadBudgetExceeded" and .storage_mutated == false and .bytes_read == 0' \
  "$preparation_dir/maintenance-read-bound.json" >/dev/null
preparation_fingerprint "$preparation_target" >"$preparation_dir/read-bound-after"
cmp -s "$preparation_dir/inspect-before" "$preparation_dir/read-bound-after"
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

LEDGER_PREPARATION_MEASURE="$preparation_dir/applied-measurement.json" \
  "$preparation_probe" prepare --definition "$event_definition" \
  --store-root "$preparation_target" --store-id preparation-smoke \
  --source-root "$preparation_source" --apply --format json >"$preparation_dir/applied.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2 and .phase == "committed" and .selected_bytes < 1048576 and .bytes_read < 1048576 and .reclaimed_bytes == 0 and .staged_bytes == .selected_bytes' \
  "$preparation_dir/applied.json" >/dev/null
preparation_measurement_result "$preparation_dir/applied-measurement.json" "$preparation_dir/applied.json"
"$json_cli" -e --slurpfile result "$preparation_dir/applied.json" \
  --argjson receipt_bytes "$(wc -c <"$preparation_target/.ledger/.preparation.json")" '
  .target_bytes_written > $result[0].selected_bytes and
  .native_stage_bytes_written == ($result[0].selected_bytes + $receipt_bytes) and
  .native_stage_creations == 4 and .streaming_bytes_written > 0 and
  .peak_native_working_bytes > 0 and .retained.native_working_bytes == 0 and
  .retained.preparation_bytes == 0 and .reclaimed_native_bytes == 0 and
  .retained.native_audit_bytes > 0 and .retained.canonical_bytes == $result[0].selected_bytes
' "$preparation_dir/applied-measurement.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_target/.ledger/example/events.jsonl"
test ! -e "$preparation_target/.ledger/unrelated-cas"
test ! -e "$preparation_target/.ledger/.preparation"
"$binary" project --definition "$event_definition" --projection all \
  --store-root "$preparation_target" --store-id preparation-smoke \
  --format jsonl >"$preparation_dir/projection.jsonl"
cmp -s "$preparation_dir/expected.jsonl" "$preparation_dir/projection.jsonl"

for preparation_doctor_case in finalized absent malformed legacy; do
  preparation_doctor_root="$preparation_dir/doctor-$preparation_doctor_case"
  cp -R "$preparation_target" "$preparation_doctor_root"
  preparation_doctor_expected_status=0
  case "$preparation_doctor_case" in
    absent) rm "$preparation_doctor_root/.ledger/.preparation.json" ;;
    malformed)
      printf '{' >"$preparation_doctor_root/.ledger/.preparation.json"
      preparation_doctor_expected_status=2
      ;;
    legacy)
      mkdir "$preparation_doctor_root/.ledger/.preparation"
      preparation_doctor_expected_status=2
      ;;
  esac
  preparation_fingerprint "$preparation_doctor_root" >"$preparation_dir/doctor-before"
  preparation_doctor_status=0
  "$binary" doctor --definition "$event_definition" \
    --store-root "$preparation_doctor_root" --store-id preparation-smoke \
    --format json >"$preparation_dir/doctor-$preparation_doctor_case.json" || preparation_doctor_status=$?
  test "$preparation_doctor_status" -eq "$preparation_doctor_expected_status"
  "$json_cli" -e --argjson healthy "$([ "$preparation_doctor_expected_status" -eq 0 ] && printf true || printf false)" '
    .healthy == $healthy and .preparation_pending == ($healthy | not) and
    (.preparation_error == null) == $healthy and .pending_transactions == 0 and
    .storage_mutated == false and (.slots | length) == 1 and
    (.slots | all(.healthy and .binding_rows == 2))
  ' "$preparation_dir/doctor-$preparation_doctor_case.json" >/dev/null
  preparation_doctor_status=0
  "$binary" doctor --definition "$event_definition" \
    --store-root "$preparation_doctor_root" --store-id preparation-smoke \
    --format text >"$preparation_dir/doctor-$preparation_doctor_case.txt" || preparation_doctor_status=$?
  test "$preparation_doctor_status" -eq "$preparation_doctor_expected_status"
  if [ "$preparation_doctor_expected_status" -eq 0 ]; then
    grep -q '^healthy ' "$preparation_dir/doctor-$preparation_doctor_case.txt"
  else
    grep -q '^unhealthy ' "$preparation_dir/doctor-$preparation_doctor_case.txt"
  fi
  preparation_fingerprint "$preparation_doctor_root" >"$preparation_dir/doctor-after"
  cmp -s "$preparation_dir/doctor-before" "$preparation_dir/doctor-after"
  "$binary" project --definition "$event_definition" --projection all \
    --store-root "$preparation_doctor_root" --store-id preparation-smoke \
    --format jsonl >"$preparation_dir/doctor-projection.jsonl"
  cmp -s "$preparation_dir/expected.jsonl" "$preparation_dir/doctor-projection.jsonl"
done

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
LEDGER_PREPARATION_MEASURE="$preparation_dir/restore-measurement.json" \
  "$preparation_probe" prepare --definition "$event_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply \
  --format json >"$preparation_dir/restored.json"
"$json_cli" -e --argjson payload_bytes "$(wc -c <"$preparation_dir/expected.jsonl")" \
  '.outcome == "prepared" and .records == 2 and .staged_bytes == $payload_bytes' \
  "$preparation_dir/restored.json" >/dev/null
"$json_cli" -e --slurpfile result "$preparation_dir/restored.json" \
  --argjson receipt_bytes "$(wc -c <"$preparation_target/.ledger/.preparation.json")" '
  .native_stage_creations == 2 and
  .native_stage_bytes_written == ($result[0].staged_bytes + $receipt_bytes) and
  .retained.preparation_bytes == 0 and .retained.native_working_bytes == 0
' "$preparation_dir/restore-measurement.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_target/.ledger/example/events.jsonl"
cmp -s "$preparation_dir/binding-before" "$preparation_binding"

preparation_selected_bytes=$("$json_cli" -r '.selected_bytes' "$preparation_dir/inspect.json")

preparation_no_bulk() {
  test ! -e "$1/.ledger/.preparation"
  test -z "$(find "$1/.ledger" -name '.ledger-dtx-stage-*' -print -quit)"
  test -z "$(find "$1" -type d -name '*archive*' -print -quit)"
}

preparation_project_expected() {
  "$binary" project --definition "$event_definition" --projection all \
    --store-root "$1" --store-id preparation-smoke --format jsonl >"$2"
  cmp -s "$preparation_dir/expected.jsonl" "$2"
}

preparation_stable_covered() {
  local target=$1
  preparation_fingerprint "$target" >"$preparation_dir/recovered-before"
  for ((preparation_retry=0; preparation_retry<100; preparation_retry++)); do
    LEDGER_PREPARATION_MEASURE="$preparation_dir/recovered-measurement-latest.json" \
      "$preparation_probe" prepare --definition "$event_definition" \
      --store-root "$target" --store-id preparation-smoke \
      --source-root "$preparation_source" --apply --format json \
      >"$preparation_dir/recovered-result-latest.json"
    "$json_cli" -e '
      .outcome == "covered" and .records == 2 and .transaction_id == null and
      .staged_bytes == 0 and .storage_mutated == false
    ' "$preparation_dir/recovered-result-latest.json" >/dev/null
    preparation_measurement_check "$preparation_dir/recovered-measurement-latest.json"
    "$json_cli" -e '
      .target_bytes_written == 0 and .native_stage_creations == 0 and
      .peak_additional_working_bytes == 0 and .initial == .retained and
      .retained.preparation_bytes == 0 and .retained.native_working_bytes == 0 and
      .reclaimed_native_bytes == 0
    ' "$preparation_dir/recovered-measurement-latest.json" >/dev/null
  done
  preparation_fingerprint "$target" >"$preparation_dir/recovered-after"
  cmp -s "$preparation_dir/recovered-before" "$preparation_dir/recovered-after"
}

for preparation_capture_fault in creation capture; do
  preparation_capture_root="$preparation_dir/interrupted-$preparation_capture_fault"
  preparation_init "$preparation_capture_root"
  cp "$preparation_capture_root/.ledger-root.json" "$preparation_dir/capture-marker.json"
  for ((preparation_retry=0; preparation_retry<100; preparation_retry++)); do
    preparation_fault_status=0
    LEDGER_PREPARATION_MEASURE="$preparation_dir/capture-measurement-latest.json" \
      LEDGER_PREPARATION_FAULT="$preparation_capture_fault" "$preparation_probe" prepare \
      --definition "$event_definition" --store-root "$preparation_capture_root" \
      --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
      >"$preparation_dir/capture-failure-latest.json" || preparation_fault_status=$?
    test "$preparation_fault_status" -eq 99
    preparation_measurement_check "$preparation_dir/capture-measurement-latest.json"
    "$json_cli" -e --arg fault "$preparation_capture_fault" --argjson selected "$preparation_selected_bytes" '
      .native_stage_creations == 1 and .retained.preparation_bytes == 0 and
      .retained.canonical_bytes == 0 and .peak_working_bytes <= ($selected + 4194304) and
      (if $fault == "creation" then .native_stage_bytes_written == 0
       else .native_stage_bytes_written > 0 end)
    ' "$preparation_dir/capture-measurement-latest.json" >/dev/null
    test "$(find "$preparation_capture_root/.ledger/.transactions" -name transaction.json -type f | wc -l)" -eq 1
    test "$(find "$preparation_capture_root/.ledger/.transactions" -maxdepth 1 -type d -name 'dtx-*' | wc -l)" -eq 1
    preparation_capture_journal=$(find "$preparation_capture_root/.ledger/.transactions" -name transaction.json -type f -print -quit)
    "$json_cli" -e '.state == "preparing" and (.writes | length) > 0' "$preparation_capture_journal" >/dev/null
    preparation_work_bytes=$(find "$preparation_capture_root/.ledger/.transactions" -type f -exec wc -c {} \; | awk '{sum += $1} END {print sum + 0}')
    test "$preparation_work_bytes" -le "$((preparation_selected_bytes + 1048576))"
    test ! -e "$preparation_capture_root/.ledger/.preparation"
    test ! -e "$preparation_capture_root/.ledger/.preparation.json"
    test ! -e "$preparation_capture_root/.ledger/example/events.jsonl"
    test -z "$(find "$preparation_capture_root" -type d -name '*archive*' -print -quit)"
    cmp -s "$preparation_dir/capture-marker.json" "$preparation_capture_root/.ledger-root.json"
    cmp -s "$preparation_dir/expected.jsonl" "$preparation_source/.ledger/example/events.jsonl"
  done
  LEDGER_PREPARATION_MEASURE="$preparation_dir/capture-recovery-measurement.json" \
    "$preparation_probe" prepare --definition "$event_definition" \
    --store-root "$preparation_capture_root" --store-id preparation-smoke \
    --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/capture-recovered.json"
  "$json_cli" -e '.outcome == "prepared" and .records == 2 and .reclaimed_bytes == null' \
    "$preparation_dir/capture-recovered.json" >/dev/null
  preparation_measurement_check "$preparation_dir/capture-recovery-measurement.json"
  "$json_cli" -e '.reclaimed_native_bytes > 0 and .retained.preparation_bytes == 0 and .retained.native_working_bytes == 0' \
    "$preparation_dir/capture-recovery-measurement.json" >/dev/null
  preparation_no_bulk "$preparation_capture_root"
  preparation_project_expected "$preparation_capture_root" "$preparation_dir/capture-projection.jsonl"
  preparation_stable_covered "$preparation_capture_root"
done

preparation_bootstrap_root="$preparation_dir/interrupted-bootstrap"
preparation_init "$preparation_bootstrap_root"
cp "$preparation_bootstrap_root/.ledger-root.json" "$preparation_dir/bootstrap-marker.json"
preparation_fault_status=0
LEDGER_PREPARATION_MEASURE="$preparation_dir/bootstrap-measurement.json" \
  LEDGER_PREPARATION_FAULT=bootstrap "$preparation_probe" prepare --definition "$event_definition" \
  --store-root "$preparation_bootstrap_root" --store-id preparation-smoke \
  --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/bootstrap-failure.json" || preparation_fault_status=$?
test "$preparation_fault_status" -eq 99
preparation_measurement_check "$preparation_dir/bootstrap-measurement.json"
"$json_cli" -e '.native_stage_creations == 0 and .retained.canonical_bytes == 0' \
  "$preparation_dir/bootstrap-measurement.json" >/dev/null
for ((preparation_retry=0; preparation_retry<=100; preparation_retry++)); do
  preparation_fault_status=0
  LEDGER_PREPARATION_MEASURE="$preparation_dir/bootstrap-retry-measurement.json" \
    "$preparation_probe" prepare --definition "$event_definition" \
    --store-root "$preparation_bootstrap_root" --store-id preparation-smoke \
    --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/bootstrap-retry.json" || preparation_fault_status=$?
  test "$preparation_fault_status" -eq 2
  "$json_cli" -e '.outcome == "recovery-required" and .transaction_id == null and .error_code != null' \
    "$preparation_dir/bootstrap-retry.json" >/dev/null
  preparation_measurement_check "$preparation_dir/bootstrap-retry-measurement.json"
  "$json_cli" -e '.native_stage_creations == 0 and .native_stage_bytes_written == 0 and .retained.canonical_bytes == 0' \
    "$preparation_dir/bootstrap-retry-measurement.json" >/dev/null
  test "$(find "$preparation_bootstrap_root/.ledger/.transactions" -maxdepth 1 -type d -name 'dtx-*' | wc -l)" -eq 1
  preparation_fingerprint "$preparation_bootstrap_root" >"$preparation_dir/bootstrap-latest"
  if test "$preparation_retry" -eq 0; then
    cp "$preparation_dir/bootstrap-latest" "$preparation_dir/bootstrap-first"
  else
    cmp -s "$preparation_dir/bootstrap-first" "$preparation_dir/bootstrap-latest"
  fi
  cmp -s "$preparation_dir/bootstrap-marker.json" "$preparation_bootstrap_root/.ledger-root.json"
done
test ! -e "$preparation_bootstrap_root/.ledger/.preparation.json"
test ! -e "$preparation_bootstrap_root/.ledger/example/events.jsonl"

for preparation_fault in journal_failure journal_cleanup_failure committed_sync publication_busy; do
  preparation_fault_root="$preparation_dir/observed-$preparation_fault"
  preparation_init "$preparation_fault_root"
  preparation_fault_status=0
  LEDGER_PREPARATION_MEASURE="$preparation_dir/observed-$preparation_fault-measurement.json" \
    LEDGER_PREPARATION_FAULT="$preparation_fault" "$preparation_probe" prepare \
    --definition "$event_definition" --store-root "$preparation_fault_root" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/observed-$preparation_fault.json" || preparation_fault_status=$?
  test "$preparation_fault_status" -eq 2
  preparation_measurement_check "$preparation_dir/observed-$preparation_fault-measurement.json"
  "$json_cli" -e '.phase == "publication" and .storage_mutated == true and .records == 2' \
    "$preparation_dir/observed-$preparation_fault.json" >/dev/null
  case "$preparation_fault" in
    journal_failure)
      "$json_cli" -e '.outcome == "failure" and .error_code == "InputOutput" and .transaction_id == null' \
        "$preparation_dir/observed-$preparation_fault.json" >/dev/null
      test -z "$(find "$preparation_fault_root/.ledger/.transactions" -name transaction.json -print)"
      test ! -e "$preparation_fault_root/.ledger/example/events.jsonl"
      ;;
    journal_cleanup_failure)
      "$json_cli" -e '.outcome == "unknown" and .error_code == "InputOutput" and .transaction_id != null' \
        "$preparation_dir/observed-$preparation_fault.json" >/dev/null
      preparation_fault_id=$("$json_cli" -r '.transaction_id' "$preparation_dir/observed-$preparation_fault.json")
      test -d "$preparation_fault_root/.ledger/.transactions/$preparation_fault_id"
      test ! -e "$preparation_fault_root/.ledger/example/events.jsonl"
      ;;
    committed_sync)
      "$json_cli" -e '.outcome == "committed-with-later-failure" and .error_code == "InputOutput" and .transaction_id != null' \
        "$preparation_dir/observed-$preparation_fault.json" >/dev/null
      preparation_fault_id=$("$json_cli" -r '.transaction_id' "$preparation_dir/observed-$preparation_fault.json")
      "$json_cli" -e '.state == "committed"' \
        "$preparation_fault_root/.ledger/.transactions/$preparation_fault_id/transaction.json" >/dev/null
      test -f "$preparation_fault_root/.ledger/.transactions/$preparation_fault_id/commit.json"
      cmp -s "$preparation_dir/expected.jsonl" "$preparation_fault_root/.ledger/example/events.jsonl"
      ;;
    publication_busy)
      "$json_cli" -e '.outcome == "recovery-required" and .error_code == "LockBusy" and .transaction_id != null' \
        "$preparation_dir/observed-$preparation_fault.json" >/dev/null
      preparation_fault_id=$("$json_cli" -r '.transaction_id' "$preparation_dir/observed-$preparation_fault.json")
      "$json_cli" -e '.state == "preparing"' \
        "$preparation_fault_root/.ledger/.transactions/$preparation_fault_id/transaction.json" >/dev/null
      test ! -e "$preparation_fault_root/.ledger/example/events.jsonl"
      ;;
  esac
  if test "$preparation_fault" != journal_cleanup_failure; then
    "$binary" prepare --definition "$event_definition" \
      --store-root "$preparation_fault_root" --store-id preparation-smoke \
      --source-root "$preparation_source" --apply --format json \
      >"$preparation_dir/observed-$preparation_fault-retry.json"
    "$json_cli" -e '.outcome == "prepared" or .outcome == "covered"' \
      "$preparation_dir/observed-$preparation_fault-retry.json" >/dev/null
    cmp -s "$preparation_dir/expected.jsonl" "$preparation_fault_root/.ledger/example/events.jsonl"
    preparation_stable_covered "$preparation_fault_root"
  fi
done

for preparation_fault in publication verification; do
  preparation_fault_root="$preparation_dir/fault-$preparation_fault"
  preparation_init "$preparation_fault_root"
  cp "$preparation_fault_root/.ledger-root.json" "$preparation_dir/fault-marker-before.json"
  preparation_fault_status=0
  LEDGER_PREPARATION_MEASURE="$preparation_dir/fault-measurement-latest.json" \
    LEDGER_PREPARATION_FAULT="$preparation_fault" "$preparation_probe" prepare \
    --definition "$event_definition" --store-root "$preparation_fault_root" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/fault-$preparation_fault.json" || preparation_fault_status=$?
  preparation_measurement_check "$preparation_dir/fault-measurement-latest.json"
  test -s "$preparation_fault_root/.ledger/.preparation.json"
  preparation_fault_journal=$(find "$preparation_fault_root/.ledger/.transactions" -name transaction.json -type f -print -quit)
  test -n "$preparation_fault_journal"
  if test "$preparation_fault" = publication; then
    test "$preparation_fault_status" -eq 99
    test ! -e "$preparation_fault_root/.ledger/example/events.jsonl"
    "$json_cli" -e '.state == "prepared"' "$preparation_fault_journal" >/dev/null
    preparation_fingerprint "$preparation_fault_root" >"$preparation_dir/publication-blocked-before"
    preparation_expect_failure recovery-required "$preparation_dir/publication-inspect.json" \
      prepare --definition "$event_definition" --store-root "$preparation_fault_root" \
      --store-id preparation-smoke --source-root "$preparation_source" --format json
    "$json_cli" -e '.transaction_id == null and .prior_preparation == null' \
      "$preparation_dir/publication-inspect.json" >/dev/null
    preparation_maintenance_status=0
    "$binary" maintain --store-root "$preparation_fault_root" --store-id preparation-smoke \
      --apply --format json >"$preparation_dir/publication-maintain.json" || preparation_maintenance_status=$?
    test "$preparation_maintenance_status" -eq 2
    "$json_cli" -e '.outcome == "blocked" and .error_code == "TransactionRecoveryRequired" and .preparation == null' \
      "$preparation_dir/publication-maintain.json" >/dev/null
    preparation_fingerprint "$preparation_fault_root" >"$preparation_dir/publication-blocked-after"
    cmp -s "$preparation_dir/publication-blocked-before" "$preparation_dir/publication-blocked-after"
  else
    test "$preparation_fault_status" -eq 2
    "$json_cli" -e '.outcome == "committed-with-later-failure" and .phase == "verification" and .transaction_id != null' \
      "$preparation_dir/fault-verification.json" >/dev/null
    "$json_cli" -e '.state == "committed"' "$preparation_fault_journal" >/dev/null
    test -f "$(dirname "$preparation_fault_journal")/commit.json"
    cmp -s "$preparation_dir/expected.jsonl" "$preparation_fault_root/.ledger/example/events.jsonl"
  fi
  LEDGER_PREPARATION_MEASURE="$preparation_dir/recovery-measurement-latest.json" \
    "$preparation_probe" prepare --definition "$event_definition" --store-root "$preparation_fault_root" \
    --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
    >"$preparation_dir/fault-$preparation_fault-retry.json"
  "$json_cli" -e '.outcome == "covered" and .records == 2 and .staged_bytes == 0 and .transaction_id == null' \
    "$preparation_dir/fault-$preparation_fault-retry.json" >/dev/null
  preparation_measurement_check "$preparation_dir/recovery-measurement-latest.json"
  "$json_cli" -e --argjson selected "$preparation_selected_bytes" '
    .native_stage_creations == 0 and .native_stage_bytes_written == 0 and
    .retained.preparation_bytes == 0 and .retained.native_working_bytes == 0 and
    .retained.canonical_bytes == $selected and .peak_working_bytes <= (3 * $selected + 4194304)
  ' "$preparation_dir/recovery-measurement-latest.json" >/dev/null
  cmp -s "$preparation_dir/fault-marker-before.json" "$preparation_fault_root/.ledger-root.json"
  preparation_no_bulk "$preparation_fault_root"
  preparation_project_expected "$preparation_fault_root" "$preparation_dir/fault-projection.jsonl"
  preparation_stable_covered "$preparation_fault_root"
done

preparation_fingerprint "$preparation_target" >"$preparation_dir/maintenance-before"
for ((preparation_retry=0; preparation_retry<100; preparation_retry++)); do
  preparation_maintenance_status=0
  LEDGER_PREPARATION_MEASURE="$preparation_dir/maintenance-failure-measurement.json" \
    LEDGER_PREPARATION_FAULT=inspection "$preparation_probe" maintain \
    --store-root "$preparation_target" --store-id preparation-smoke --apply --format json \
    >"$preparation_dir/maintenance-failure.json" || preparation_maintenance_status=$?
  test "$preparation_maintenance_status" -eq 2
  "$json_cli" -e '.outcome == "failure" and .phase == "inspection" and .error_code == "InputOutput" and .storage_mutated == false' \
    "$preparation_dir/maintenance-failure.json" >/dev/null
  preparation_measurement_check "$preparation_dir/maintenance-failure-measurement.json"
  "$json_cli" -e '.target_bytes_written == 0 and .reclaimed_native_bytes == 0 and .initial == .retained' \
    "$preparation_dir/maintenance-failure-measurement.json" >/dev/null
done
"$binary" maintain --store-root "$preparation_target" --store-id preparation-smoke \
  --apply --format json >"$preparation_dir/maintenance-recovered.json"
"$json_cli" -e '.outcome == "healthy" and .storage_mutated == false and .preparation.installed == true and .preparation.complete == true and .preparation.reclaimed_bytes == 0' \
  "$preparation_dir/maintenance-recovered.json" >/dev/null
preparation_fingerprint "$preparation_target" >"$preparation_dir/maintenance-after"
cmp -s "$preparation_dir/maintenance-before" "$preparation_dir/maintenance-after"
preparation_project_expected "$preparation_target" "$preparation_dir/maintenance-projection.jsonl"

preparation_legacy_root="$preparation_dir/legacy-working-files"
preparation_init "$preparation_legacy_root"
mkdir "$preparation_legacy_root/.ledger/.preparation"
printf retained >"$preparation_legacy_root/.ledger/.preparation/payload-0"
printf '%s\n' '{"schema":"ledger-preparation/v1","phase":"capturing","installed":false,"files":[],"provenance":[]}' \
  >"$preparation_legacy_root/.ledger/.preparation/operation.json"
preparation_fingerprint "$preparation_legacy_root" >"$preparation_dir/legacy-before"
preparation_expect_failure PreparationOwnershipUnknown "$preparation_dir/legacy-prepare.json" \
  prepare --definition "$event_definition" --store-root "$preparation_legacy_root" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply --format json
preparation_maintenance_status=0
"$binary" maintain --store-root "$preparation_legacy_root" --store-id preparation-smoke \
  --apply --format json >"$preparation_dir/legacy-maintain.json" || preparation_maintenance_status=$?
test "$preparation_maintenance_status" -eq 2
"$json_cli" -e '.outcome == "blocked" and .error_code == "PreparationOwnershipUnknown" and .storage_mutated == false' \
  "$preparation_dir/legacy-maintain.json" >/dev/null
preparation_fingerprint "$preparation_legacy_root" >"$preparation_dir/legacy-after"
cmp -s "$preparation_dir/legacy-before" "$preparation_dir/legacy-after"

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

# The manifest must attest both selected native files, including their bytes.
cp "$preparation_dir/legacy-archive/fixture/manifest.json" "$preparation_dir/archive-manifest-before.json"
preparation_archive_binding=$(find "$preparation_archive/.ledger/.bindings" -name '*.jsonl' -type f -print -quit)
for preparation_required_entry in .ledger/example/events.jsonl "${preparation_archive_binding#"$preparation_archive/"}"; do
  "$json_cli" --arg path "$preparation_required_entry" 'del(.sources["0"].entries[$path])' \
    "$preparation_dir/archive-manifest-before.json" >"$preparation_dir/legacy-archive/fixture/manifest.json"
  preparation_expect_failure PreparationArchiveEvidenceMissing "$preparation_dir/archive-inventory-missing.json" \
    prepare --definition "$event_definition" --store-root "$preparation_empty" \
    --store-id preparation-smoke --source-archive "$preparation_archive" --apply --format json
done
"$json_cli" '.sources["0"].entries[".ledger/example/events.jsonl"].sha256 = "untrusted-digest"' \
  "$preparation_dir/archive-manifest-before.json" >"$preparation_dir/legacy-archive/fixture/manifest.json"
preparation_expect_failure PreparationArchiveEvidenceMismatch "$preparation_dir/archive-digest-mismatch.json" \
  prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-archive "$preparation_archive" --apply --format json
cp "$preparation_dir/archive-manifest-before.json" "$preparation_dir/legacy-archive/fixture/manifest.json"

# Manifest selection cannot turn a damaged generation into empty history.
mv "$preparation_archive/.ledger/example/events.jsonl" "$preparation_dir/archive-event-retained"
preparation_expect_failure StoreBindingWithoutSlot "$preparation_dir/archive-event-missing.json" \
  prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-archive "$preparation_archive" --apply --format json
mv "$preparation_dir/archive-event-retained" "$preparation_archive/.ledger/example/events.jsonl"
mv "$preparation_archive/.ledger/.bindings" "$preparation_dir/archive-bindings-retained"
preparation_expect_failure StoreSlotWithoutBinding "$preparation_dir/archive-binding-missing.json" \
  prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-archive "$preparation_archive" --apply --format json
mv "$preparation_dir/archive-bindings-retained" "$preparation_archive/.ledger/.bindings"
test ! -e "$preparation_empty/.ledger/example/events.jsonl"

# An explicit candidate can restore only the exact surviving native binding.
# This is not a fixture for the unpublished flat archive inventory: the schema
# marker deliberately carries no authority to admit history through that route.
preparation_flat="$preparation_dir/flat-evidence/legacy-archive/worktree-0"
preparation_flat_target="$preparation_dir/flat-bound-target"
mkdir -p "$preparation_flat/.ledger"
cp -R "$preparation_source/.ledger/example" "$preparation_source/.ledger/.bindings" \
  "$preparation_source/.ledger/.definitions" "$preparation_flat/.ledger/"
printf '%s\n' '{"schema":"ledger-legacy-archive/v1"}' \
  >"$preparation_dir/flat-evidence/legacy-archive/manifest.json"
preparation_init "$preparation_flat_target"
cp -R "$preparation_flat/.ledger/.bindings" "$preparation_flat/.ledger/.definitions" \
  "$preparation_flat_target/.ledger/"
"$binary" prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --format json >"$preparation_dir/flat-bound-ready.json"
"$json_cli" -e '.outcome == "ready" and .records == 2 and .storage_mutated == false' \
  "$preparation_dir/flat-bound-ready.json" >/dev/null
# A prior inspection cannot authorize initialization if the target binding is
# lost before apply. The explicit bound-history guard is checked again.
mv "$preparation_flat_target/.ledger/.bindings" "$preparation_dir/flat-target-bindings-retained"
preparation_fingerprint "$preparation_flat_target" >"$preparation_dir/flat-unbound-before"
preparation_expect_failure PreparationRequiresBoundHistory "$preparation_dir/flat-target-unbound.json" \
  prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --apply --format json
"$json_cli" -e '.storage_mutated == false' "$preparation_dir/flat-target-unbound.json" >/dev/null
preparation_fingerprint "$preparation_flat_target" >"$preparation_dir/flat-unbound-after"
cmp -s "$preparation_dir/flat-unbound-before" "$preparation_dir/flat-unbound-after"
mv "$preparation_dir/flat-target-bindings-retained" "$preparation_flat_target/.ledger/.bindings"
preparation_fingerprint "$preparation_flat_target" >"$preparation_dir/flat-target-before"
preparation_expect_failure UnsupportedLegacyArchiveLayout "$preparation_dir/flat-archive-blocked.json" \
  prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-archive "$preparation_flat" --apply --format json
preparation_fingerprint "$preparation_flat_target" >"$preparation_dir/flat-target-after"
cmp -s "$preparation_dir/flat-target-before" "$preparation_dir/flat-target-after"

mv "$preparation_flat/.ledger/example/events.jsonl" "$preparation_dir/flat-event-retained"
preparation_expect_failure StoreBindingWithoutSlot "$preparation_dir/flat-event-missing.json" \
  prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --apply --format json
ln -s "$preparation_dir/flat-event-retained" "$preparation_flat/.ledger/example/events.jsonl"
preparation_expect_failure SymlinkComponent "$preparation_dir/flat-event-symlink.json" \
  prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --apply --format json
rm "$preparation_flat/.ledger/example/events.jsonl"
mv "$preparation_dir/flat-event-retained" "$preparation_flat/.ledger/example/events.jsonl"
mv "$preparation_flat/.ledger/.bindings" "$preparation_dir/flat-bindings-retained"
preparation_expect_failure StoreSlotWithoutBinding "$preparation_dir/flat-binding-missing.json" \
  prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --apply --format json
mv "$preparation_dir/flat-bindings-retained" "$preparation_flat/.ledger/.bindings"
preparation_fingerprint "$preparation_flat_target" >"$preparation_dir/flat-target-after"
cmp -s "$preparation_dir/flat-target-before" "$preparation_dir/flat-target-after"

preparation_fingerprint "$preparation_conflict" >"$preparation_dir/flat-conflict-before"
preparation_expect_failure PreparationBindingConflict "$preparation_dir/flat-binding-conflict.json" \
  prepare --definition "$event_definition" --store-root "$preparation_conflict" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --apply --format json
preparation_fingerprint "$preparation_conflict" >"$preparation_dir/flat-conflict-after"
cmp -s "$preparation_dir/flat-conflict-before" "$preparation_dir/flat-conflict-after"
preparation_fingerprint "$preparation_dir/flat-evidence" >"$preparation_dir/flat-evidence-before"
"$binary" prepare --definition "$event_definition" --store-root "$preparation_flat_target" \
  --store-id preparation-smoke --restore-bound-history --source-root "$preparation_flat" \
  --confirm-no-legacy-writers --apply --format json >"$preparation_dir/flat-bound-restored.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2 and .authority_granted == false' \
  "$preparation_dir/flat-bound-restored.json" >/dev/null
cmp -s "$preparation_dir/expected.jsonl" "$preparation_flat_target/.ledger/example/events.jsonl"
preparation_flat_binding=$(find "$preparation_flat_target/.ledger/.bindings" -name '*.jsonl' -type f -print -quit)
cmp -s "$preparation_dir/binding-before" "$preparation_flat_binding"
preparation_fingerprint "$preparation_dir/flat-evidence" >"$preparation_dir/flat-evidence-after"
cmp -s "$preparation_dir/flat-evidence-before" "$preparation_dir/flat-evidence-after"

preparation_required=$(find "$preparation_archive/.ledger/.definitions" -name '*.json' -type f -print -quit)
cp "$preparation_required" "$preparation_dir/required-before.json"
printf '%s\n' '{}' >"$preparation_required"
preparation_status=0
"$binary" prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-archive "$preparation_archive" --format json \
  >"$preparation_dir/required-corrupt.json" || preparation_status=$?
test "$preparation_status" -eq 2
"$json_cli" -e '.schema == "ledger-preparation-result/v1" and .error_code != null and .storage_mutated == false and .bytes_read > 0' \
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

preparation_expect_failure HistoricalDependencyBoundExceeded "$preparation_dir/dependency-limit.json" \
  prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-root "$preparation_source" --max-files 2 --format json
"$json_cli" -e '.outcome == "incomplete" and .storage_mutated == false' \
  "$preparation_dir/dependency-limit.json" >/dev/null
"$binary" prepare --definition "$event_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-root "$preparation_source" --max-files 3 --format json \
  >"$preparation_dir/dependency-exact.json"
"$json_cli" -e '.outcome == "ready" and .records == 2 and .storage_mutated == false' \
  "$preparation_dir/dependency-exact.json" >/dev/null

preparation_prior_limit=$(( $(wc -c <"$preparation_target/.ledger-root.json") + 1 ))
preparation_fingerprint "$preparation_target" >"$preparation_dir/prior-limit-before"
preparation_expect_failure ReadBudgetExceeded "$preparation_dir/prior-limit.json" \
  prepare --definition "$event_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --max-read-bytes "$preparation_prior_limit" --format json
"$json_cli" -e '.outcome == "incomplete" and .phase == "prior-inspection" and .storage_mutated == false' \
  "$preparation_dir/prior-limit.json" >/dev/null
preparation_fingerprint "$preparation_target" >"$preparation_dir/prior-limit-after"
cmp -s "$preparation_dir/prior-limit-before" "$preparation_dir/prior-limit-after"

preparation_partial="$preparation_dir/partial-recovery"
preparation_init "$preparation_partial"
preparation_fault_status=0
LEDGER_PREPARATION_FAULT=capture "$preparation_probe" prepare --definition "$event_definition" \
  --store-root "$preparation_partial" --store-id preparation-smoke \
  --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/partial-capture.json" || preparation_fault_status=$?
test "$preparation_fault_status" -eq 99
preparation_expect_failure recovery-required "$preparation_dir/partial-inspect.json" \
  prepare --definition "$event_definition" --store-root "$preparation_partial" \
  --store-id preparation-smoke --format json
preparation_pending_limit=$(( $("$json_cli" -r '.bytes_read' "$preparation_dir/partial-inspect.json") - $(wc -c <"$preparation_partial/.ledger-root.json") + 1 ))
preparation_expect_failure ReadBudgetExceeded "$preparation_dir/pending-limit.json" \
  prepare --definition "$event_definition" --store-root "$preparation_partial" \
  --store-id preparation-smoke --apply --max-read-bytes "$preparation_pending_limit" --format json
"$json_cli" -e '.outcome == "recovery-required" and .storage_mutated == false' \
  "$preparation_dir/pending-limit.json" >/dev/null
test "$(find "$preparation_partial/.ledger" -name '.ledger-dtx-stage-*' -type f | wc -l)" -eq 1
preparation_fault_status=0
LEDGER_PREPARATION_FAULT=recovery LEDGER_PREPARATION_MEASURE="$preparation_dir/partial-measurement.json" \
  "$preparation_probe" prepare --definition "$event_definition" \
  --store-root "$preparation_partial" --store-id preparation-smoke \
  --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/partial-recovery.json" || preparation_fault_status=$?
test "$preparation_fault_status" -eq 2
"$json_cli" -e '.outcome == "recovery-required" and .phase == "recovery" and .error_code == "AccessDenied" and .storage_mutated == true and .reclaimed_bytes == null' \
  "$preparation_dir/partial-recovery.json" >/dev/null
"$json_cli" -e '.reclaimed_native_bytes > 0' "$preparation_dir/partial-measurement.json" >/dev/null
test -z "$(find "$preparation_partial/.ledger" -name '.ledger-dtx-stage-*' -type f -print -quit)"
"$binary" prepare --definition "$event_definition" --store-root "$preparation_partial" \
  --store-id preparation-smoke --source-root "$preparation_source" --apply --format json \
  >"$preparation_dir/partial-recovered.json"
"$json_cli" -e '.outcome == "prepared" and .records == 2' "$preparation_dir/partial-recovered.json" >/dev/null
preparation_project_expected "$preparation_partial" "$preparation_dir/partial-projection.jsonl"

preparation_small_definition="$preparation_dir/small-definition.json"
"$json_cli" -c '.id = "example/small" | .storage.slots.events.path = "example/small.jsonl"' \
  "$event_definition" >"$preparation_small_definition"
"$binary" prepare --definition "$preparation_small_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --max-bytes 1 --max-files 2 --format json \
  >"$preparation_dir/prior-receipt-small-limits.json"
"$json_cli" -e '.outcome == "empty" and .storage_mutated == false and .prior_preparation.complete == true' \
  "$preparation_dir/prior-receipt-small-limits.json" >/dev/null
"$binary" maintain --store-root "$preparation_target" --store-id preparation-smoke \
  --max-bytes 1 --format json >"$preparation_dir/prior-receipt-maintain.json"
"$json_cli" -e '.outcome == "healthy" and .preparation.installed == true' \
  "$preparation_dir/prior-receipt-maintain.json" >/dev/null
preparation_small_source="$preparation_dir/small-source"
mkdir "$preparation_small_source"
"$binary" transact --definition "$preparation_small_definition" --operation append \
  --repo "$preparation_small_source" --input "event=$event_input" --param request=small \
  --format json >"$preparation_dir/small-source.json"
"$binary" prepare --definition "$preparation_small_definition" --store-root "$preparation_empty" \
  --store-id preparation-smoke --source-root "$preparation_small_source" --format json \
  >"$preparation_dir/small-inspect.json"
preparation_small_bytes=$("$json_cli" -r '.selected_bytes' "$preparation_dir/small-inspect.json")
test "$preparation_small_bytes" -lt "$preparation_selected_bytes"
"$binary" prepare --definition "$preparation_small_definition" --store-root "$preparation_target" \
  --store-id preparation-smoke --source-root "$preparation_small_source" \
  --max-bytes "$preparation_small_bytes" --apply --format json >"$preparation_dir/small-applied.json"
"$json_cli" -e '.outcome == "prepared" and .records == 1' "$preparation_dir/small-applied.json" >/dev/null
"$binary" project --definition "$preparation_small_definition" --projection all \
  --store-root "$preparation_target" --store-id preparation-smoke --format jsonl \
  >"$preparation_dir/small-projection.jsonl"
"$json_cli" -c . "$event_input" >"$preparation_dir/small-expected.jsonl"
cmp -s "$preparation_dir/small-expected.jsonl" "$preparation_dir/small-projection.jsonl"
preparation_project_expected "$preparation_target" "$preparation_dir/prior-owner-preserved.jsonl"

preparation_replacement_definition="$preparation_dir/replacement-definition.json"
"$json_cli" -c '.parameters |= del(.stream) | .storage.slots.events.path = "example/snapshots.jsonl"' \
  "$event_snapshot_definition" >"$preparation_replacement_definition"
preparation_replacement_source="$preparation_dir/replacement-source"
preparation_replacement_old="$preparation_dir/replacement-old"
preparation_replacement_target="$preparation_dir/replacement-target"
preparation_replacement_prefix="$preparation_dir/replacement-prefix"
mkdir "$preparation_replacement_source" "$preparation_replacement_old"
preparation_init "$preparation_replacement_target"
preparation_init "$preparation_replacement_prefix"
"$binary" transact --definition "$preparation_replacement_definition" --operation create \
  --repo "$preparation_replacement_source" --input "snapshot=$event_snapshot_initial" --format json \
  >"$preparation_dir/replacement-create.json"
cp -R "$preparation_replacement_source/.ledger" "$preparation_replacement_old/.ledger"
cp -R "$preparation_replacement_source/.ledger/." "$preparation_replacement_prefix/.ledger/"
"$binary" transact --definition "$preparation_replacement_definition" --operation replace \
  --repo "$preparation_replacement_source" --input "snapshot=$event_snapshot_replacement" \
  --param request=replace --format json >"$preparation_dir/replacement-write.json"
"$binary" prepare --definition "$preparation_replacement_definition" \
  --store-root "$preparation_replacement_target" --store-id preparation-smoke \
  --source-root "$preparation_replacement_old" --source-root "$preparation_replacement_source" \
  --apply --format json >"$preparation_dir/replacement-applied.json"
"$json_cli" -e '.outcome == "prepared"' "$preparation_dir/replacement-applied.json" >/dev/null
"$binary" project --definition "$preparation_replacement_definition" --projection all \
  --store-root "$preparation_replacement_target" --store-id preparation-smoke --format jsonl \
  >"$preparation_dir/replacement-projection.jsonl"
cmp -s "$event_snapshot_replacement" "$preparation_dir/replacement-projection.jsonl"
preparation_fingerprint "$preparation_replacement_target" >"$preparation_dir/replacement-covered-before"
"$binary" prepare --definition "$preparation_replacement_definition" \
  --store-root "$preparation_replacement_target" --store-id preparation-smoke \
  --source-root "$preparation_replacement_old" --apply --format json \
  >"$preparation_dir/replacement-covered.json"
"$json_cli" -e '.outcome == "covered" and .storage_mutated == false' "$preparation_dir/replacement-covered.json" >/dev/null
preparation_fingerprint "$preparation_replacement_target" >"$preparation_dir/replacement-covered-after"
cmp -s "$preparation_dir/replacement-covered-before" "$preparation_dir/replacement-covered-after"
preparation_fingerprint "$preparation_replacement_prefix" >"$preparation_dir/replacement-prefix-before"
preparation_expect_failure reconciliation-required "$preparation_dir/replacement-prefix.json" \
  prepare --definition "$preparation_replacement_definition" \
  --store-root "$preparation_replacement_prefix" --store-id preparation-smoke \
  --source-root "$preparation_replacement_source" --apply --format json
preparation_fingerprint "$preparation_replacement_prefix" >"$preparation_dir/replacement-prefix-after"
cmp -s "$preparation_dir/replacement-prefix-before" "$preparation_dir/replacement-prefix-after"
