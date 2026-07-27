#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"

dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
ledger_bin=${LEDGER_BIN:-ledger}
fixture_root="$skills_zig_root/testdata/dotfiles/skill-definitions/memory-source-notes/fixtures/ledger/synesthesia-memory-note-payload"
fixture_suite="$fixture_root/cases.json"
adapter="$dotfiles_root/codex/skills/memory-source-notes/scripts/synesthesia_memory_note.py"

command -v jq >/dev/null
command -v uv >/dev/null
command -v "$ledger_bin" >/dev/null
[[ -f "$adapter" && ! -L "$adapter" ]]

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
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
      '.note |
       del(.payload.scope) |
       del(.payload.endorsement_type)' \
      "$reconstructed" >"$raw"
  elif [[ "$case_id" == "scope-global" ]]; then
    jq -S -c \
      '.note |
       del(.scope.repo) |
       del(.payload.scope) |
       del(.payload.scope_anchor) |
       del(.payload.endorsement_type)' \
      "$reconstructed" >"$raw"
  else
    jq -S -c \
      '.note |
       del(.payload.scope) |
       del(.payload.scope_anchor) |
       del(.payload.endorsement_type)' \
      "$reconstructed" >"$raw"
  fi
  logical_kind=$(jq -r '.logical_kind' "$reconstructed")

  if [[ "$expectation" == "valid" ]]; then
    valid_count=$((valid_count + 1))
    LEDGER_BIN="$ledger_bin" \
      uv run "$adapter" validate \
        --kind "$logical_kind" \
        --json "$raw" >"$output"
    jq -S -c '.note' "$reconstructed" >"$scratch/$case_id.expected-note.json"
    jq -S -c '.normalized' "$output" >"$scratch/$case_id.actual-note.json"
    cmp -s \
      "$scratch/$case_id.expected-note.json" \
      "$scratch/$case_id.actual-note.json"
    jq -e \
      --arg logical_kind "$logical_kind" \
      --arg physical_kind "$(jq -r '.physical_kind' "$reconstructed")" \
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
done < <(jq -r '.cases[] | [.id, .expect] | @tsv' "$fixture_suite")

[[ "$valid_count" -eq 9 ]]
[[ "$invalid_count" -eq 5 ]]
printf \
  'memory-source-note adapter conformance passed: valid=%d invalid=%d bases=1\n' \
  "$valid_count" \
  "$invalid_count"
