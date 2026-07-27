#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"

dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
ledger_bin=${LEDGER_BIN:-ledger}
memory_note_bin=${MEMORY_NOTE_BIN:-"$skills_zig_root/zig-out/bin/memory-note"}
fixture_root="$skills_zig_root/testdata/dotfiles/skill-definitions/memory-source-notes/fixtures/ledger/synesthesia-memory-note-payload"
fixture_source="$fixture_root/cases.json"
adapter="$dotfiles_root/codex/skills/memory-source-notes/scripts/synesthesia_memory_note.py"

command -v jq >/dev/null
command -v uv >/dev/null
command -v "$ledger_bin" >/dev/null
[[ -x "$memory_note_bin" ]]
[[ -f "$adapter" && ! -L "$adapter" ]]

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
fixture_suite="$scratch/suite.json"
materialize_definition_suite \
  "$fixture_root" \
  "$fixture_source" \
  "$fixture_suite" \
  "$scratch"
valid_count=0
invalid_count=0

while IFS=$'\t' read -r case_id expectation; do
  case "$case_id" in
    confirmation-without-prior|malformed-prior-id|mapping-without-translation|scope-anchor-priority|sensitive-nested-key)
      ;;
    *)
      if [[ "$expectation" == "invalid" ]]; then
        continue
      fi
      ;;
  esac

  reconstructed="$scratch/$case_id.json"
  raw="$scratch/$case_id.raw.json"
  output="$scratch/$case_id.output.json"
  errors="$scratch/$case_id.errors.json"
  reconstruct_definition_case \
    "$fixture_root" \
    "$fixture_suite" \
    "$case_id" \
    "$reconstructed"
  if [[ "$case_id" == "scope-anchor-priority" ]]; then
    jq -S -c \
      '.source.record |
       del(.payload.scope) |
       del(.payload.endorsement_type)' \
      "$reconstructed" >"$raw"
  elif [[ "$case_id" == "scope-global" ]]; then
    jq -S -c \
      '.source.record |
       del(.scope.repo) |
       del(.payload.scope) |
       del(.payload.scope_anchor) |
       del(.payload.endorsement_type)' \
      "$reconstructed" >"$raw"
  else
    jq -S -c \
      '.source.record |
       del(.payload.scope) |
       del(.payload.scope_anchor) |
       del(.payload.endorsement_type)' \
      "$reconstructed" >"$raw"
  fi
  logical_kind=$(jq -r '.source.logical_kind' "$reconstructed")

  if [[ "$expectation" == "valid" ]]; then
    valid_count=$((valid_count + 1))
    LEDGER_BIN="$ledger_bin" \
      uv run "$adapter" validate \
        --kind "$logical_kind" \
        --json "$raw" >"$output"
    jq -S -c '.source.record' "$reconstructed" >"$scratch/$case_id.expected-note.json"
    jq -S -c '.normalized' "$output" >"$scratch/$case_id.actual-note.json"
    cmp -s \
      "$scratch/$case_id.expected-note.json" \
      "$scratch/$case_id.actual-note.json"
    jq -e \
      --arg logical_kind "$logical_kind" \
      --arg physical_kind "$(jq -r '.source.physical_kind' "$reconstructed")" \
      '.valid == true and
       .logical_kind == $logical_kind and
       .physical_kind == $physical_kind and
       .structural_validation.id ==
         "memory-source-notes/synesthesia-memory-note-payload" and
       .structural_validation.abi == "ledger-artifact-abi/v1"' \
      "$output" >/dev/null
  else
    invalid_count=$((invalid_count + 1))
    set +e
    LEDGER_BIN="$ledger_bin" \
      uv run "$adapter" validate \
        --kind "$logical_kind" \
        --json "$raw" >"$output" 2>"$errors"
    status=$?
    set -e
    [[ "$status" -eq 2 ]]
    jq -e \
      '.synesthesia_memory_note.verdict == "fail" and
       (.synesthesia_memory_note.error |
         startswith("structurally invalid under memory-source-notes/synesthesia-memory-note-payload@sha256:"))' \
      "$errors" >/dev/null
  fi
done < <(definition_suite_case_rows "$fixture_suite")

source_definition="$dotfiles_root/codex/skills/synesthesia/definitions/ledger/synesthesia-protocol.json"
source_submission="$scratch/source-submission.json"
source_transaction="$scratch/source-transaction.json"
assert_source_doctor() {
  local repo=$1
  local state=$2
  local healthy=$3
  local expected_exit=$4

  assert_ledger_doctor_slot_state \
    "$ledger_bin" "$source_definition" "$repo" events \
    "$state" "$healthy" "$expected_exit" "$scratch/doctor-$state.json"
}

projection_repo="$scratch/projection-repo"
mkdir -p "$projection_repo"
projection_repo=$(cd "$projection_repo" && pwd -P)
run_adapter_doctor() {
  LEDGER_BIN="$ledger_bin" \
    MEMORY_NOTE_BIN="$memory_note_bin" \
    uv run "$adapter" doctor \
      --repo "$projection_repo" \
      --codex-home "$1" \
      --format json >"$2"
}

assert_source_doctor "$projection_repo" missing true 0

unbound_repo="$scratch/unbound-repo"
mkdir -p "$unbound_repo/.ledger/synesthesia"
unbound_repo=$(cd "$unbound_repo" && pwd -P)
jq -nc \
  '{schema: "synesthesia-event/v1"}' \
  >"$unbound_repo/.ledger/synesthesia/events.jsonl"
assert_source_doctor "$unbound_repo" invalid false 2

jq -S -c '.source' "$scratch/mapping-endorsement.json" >"$source_submission"
"$ledger_bin" transact \
  --definition "$source_definition" \
  --operation capture \
  --repo "$projection_repo" \
  --input "submission=$source_submission" \
  --format json >"$source_transaction"
source_id=$(jq -r '.generated_outputs.syn_id' "$source_transaction")
assert_source_doctor "$projection_repo" current true 0
jq -r '.returned_content' "$source_transaction" >"$scratch/expected-record.json"
"$ledger_bin" project \
  --definition "$source_definition" \
  --projection record \
  --repo "$projection_repo" \
  --param "id=$source_id" \
  --payload-only \
  --format json >"$scratch/actual-record.json"
cmp -s "$scratch/expected-record.json" "$scratch/actual-record.json"

jq -c \
  '.source.record |
   {
     operation: .operation,
     authority: .authority,
     summary: .summary,
     scope: .scope,
     source_refs: .source_refs,
     related_ids: .related_ids,
     supersedes_id: .supersedes_id,
     payload: .payload
   }' \
  "$scratch/mapping-endorsement.json" >"$scratch/expected-memory-note.json"
"$ledger_bin" project \
  --definition "$source_definition" \
  --projection memory-note \
  --repo "$projection_repo" \
  --param "id=$source_id" \
  --payload-only \
  --format json >"$scratch/actual-memory-note.json"
cmp -s \
  "$scratch/expected-memory-note.json" \
  "$scratch/actual-memory-note.json"

adapter_doctor_home="$scratch/adapter-doctor-home"
mkdir -p "$adapter_doctor_home"
adapter_doctor_home=$(cd "$adapter_doctor_home" && pwd -P)
for attempt in created duplicate; do
  LEDGER_BIN="$ledger_bin" \
    MEMORY_NOTE_BIN="$memory_note_bin" \
    uv run "$adapter" append \
      --kind mapping-endorsement \
      --json "$scratch/actual-memory-note.json" \
      --codex-home "$adapter_doctor_home" \
      >"$scratch/adapter-append-$attempt.json"
done
jq -e '.status == "created"' "$scratch/adapter-append-created.json" >/dev/null
jq -e '.status == "duplicate_skip"' "$scratch/adapter-append-duplicate.json" >/dev/null
"$memory_note_bin" list \
  --extension synesthesia \
  --codex-home "$adapter_doctor_home" \
  --format json >"$scratch/adapter-notes.json"
jq -e '.notes | length == 1' "$scratch/adapter-notes.json" >/dev/null
run_adapter_doctor "$adapter_doctor_home" "$scratch/adapter-doctor.json"
jq -e \
  '.synesthesia_memory_doctor.source_ledger.status == "current" and
   .synesthesia_memory_doctor.source_ledger.healthy == true and
   .synesthesia_memory_doctor.source_ledger.result.authority_granted == false and
   .synesthesia_memory_doctor.source_ledger.result.storage_mutated == false and
   .synesthesia_memory_doctor.notes.count == 1 and
   .synesthesia_memory_doctor.notes.valid_count == 1 and
   (.synesthesia_memory_doctor.notes.parse_errors | length) == 0 and
   .synesthesia_memory_doctor.digest.status == "current"' \
  "$scratch/adapter-doctor.json" >/dev/null

note_path=$(jq -r '.notes[0].path' "$scratch/adapter-notes.json")
jq '.extension = "wrong-extension"' "$note_path" >"$scratch/tampered-note.json"
mv "$scratch/tampered-note.json" "$note_path"
set +e
run_adapter_doctor \
  "$adapter_doctor_home" \
  "$scratch/adapter-doctor-invalid-note.json"
invalid_note_doctor_exit=$?
set -e
[[ "$invalid_note_doctor_exit" -eq 2 ]]
jq -e \
  '.synesthesia_memory_doctor.stage == "source-notes-invalid" and
   .synesthesia_memory_doctor.notes.valid_count == 0 and
   (.synesthesia_memory_doctor.notes.parse_errors | length) == 1' \
  "$scratch/adapter-doctor-invalid-note.json" >/dev/null

jq -r '.returned_content' "$source_transaction" |
  jq -c \
    '[.record |
      {
        id: .id,
        captured_at: .captured_at,
        kind: .kind,
        operation: .operation,
        summary: .summary
      }]' >"$scratch/expected-recent.json"
"$ledger_bin" project \
  --definition "$source_definition" \
  --projection recent \
  --repo "$projection_repo" \
  --param limit=1 \
  --payload-only \
  --format json >"$scratch/actual-recent.json"
cmp -s "$scratch/expected-recent.json" "$scratch/actual-recent.json"

jq -r '.returned_content' "$source_transaction" |
  jq -c \
    '[.record |
      {
        id: .id,
        kind: .kind,
        operation: .operation,
        summary: .summary
      }]' >"$scratch/expected-query.json"
"$ledger_bin" project \
  --definition "$source_definition" \
  --projection query \
  --repo "$projection_repo" \
  --param "query=map a sensory phrase" \
  --param search_limit=1 \
  --payload-only \
  --format json >"$scratch/actual-query.json"
cmp -s "$scratch/expected-query.json" "$scratch/actual-query.json"

jq -r '.returned_content' "$source_transaction" |
  jq -c \
    '[.record |
      {
        score: 2,
        id: .id,
        kind: .kind,
        operation: .operation,
        summary: .summary
      }]' >"$scratch/expected-recall.json"
"$ledger_bin" project \
  --definition "$source_definition" \
  --projection recall \
  --repo "$projection_repo" \
  --param "query=porous authority" \
  --param search_limit=1 \
  --payload-only \
  --format json >"$scratch/actual-recall.json"
cmp -s "$scratch/expected-recall.json" "$scratch/actual-recall.json"

[[ "$valid_count" -eq 9 ]]
[[ "$invalid_count" -eq 5 ]]
printf \
  'memory-source-note adapter conformance passed: valid=%d invalid=%d bases=1 projections=5 doctors=5\n' \
  "$valid_count" \
  "$invalid_count"
