#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"
dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
cd "$dotfiles_root"

seq_bin=${SEQ_BIN:-seq}
ledger_bin=${LEDGER_BIN:-ledger}

command -v jq >/dev/null
command -v "$seq_bin" >/dev/null
command -v "$ledger_bin" >/dev/null

manifests=$(rg --files codex/skills | LC_ALL=C sort | grep '/definitions/manifest\.json$' || true)
if [[ -z "$manifests" ]]; then
  echo "no skill definition manifests found" >&2
  exit 1
fi

manifest_count=0
seq_count=0
ledger_count=0
fixture_count=0
materialization_count=0
contract_count=0
transaction_count=0

for manifest in $manifests; do
  manifest_count=$((manifest_count + 1))
  definition_root=${manifest%/manifest.json}
  skill_root=${definition_root%/definitions}
  expected_skill=${skill_root##*/}

  jq -e \
    --arg skill "$expected_skill" \
    '
      type == "object" and
      (keys | sort) == ["ledger", "schema", "seq", "skill"] and
      .schema == "skill-definition-set/v1" and
      .skill == $skill and
      (.seq | type == "array") and
      (.ledger | type == "array") and
      all(.seq[], .ledger[];
        type == "object" and
        (keys | sort) == ["id", "path"] and
        (.id | type == "string" and length > 0) and
        (.path | type == "string" and length > 0) and
        (.path | startswith("/") | not) and
        (.path | split("/") | all(. != "" and . != "." and . != ".."))
      )
    ' \
    "$manifest" >/dev/null

  while IFS=$'\t' read -r id path; do
    [[ -n "$id" && -n "$path" ]]
    definition="$definition_root/$path"
    [[ -f "$definition" && ! -L "$definition" ]]
    case "$path" in
      seq/*)
        seq_count=$((seq_count + 1))
        "$seq_bin" definition check \
          --definition "$definition" \
          --format json |
          jq -e '.valid == true and .authority_granted == false' >/dev/null
        ;;
      ledger/*)
        ledger_count=$((ledger_count + 1))
        "$ledger_bin" definition check \
          --definition "$definition" \
          --format json |
          jq -e '.valid == true and .authority_granted == false' >/dev/null

        required_input_count=$(
          jq '[.inputs | to_entries[] | select(.value.required != false)] | length' \
            "$definition"
        )
        fixture_root="$skills_zig_root/testdata/dotfiles/skill-definitions/$expected_skill/fixtures/ledger/${id##*/}"
        fixture_suite="$fixture_root/cases.json"
        if [[ -f "$fixture_suite" && ! -L "$fixture_suite" ]]; then
          if [[ "$required_input_count" -ne 1 ]]; then
            echo "$fixture_root requires an explicit multi-input fixture runner" >&2
            exit 1
          fi
          input_name=$(
            jq -r \
              '.inputs | to_entries[] |
               select(.value.required != false) |
               .key' \
              "$definition"
          )
          jq -e \
            '
              . as $suite |
              type == "object" and
              ((keys - ["bases", "cases", "oracle", "reconstructed_cases_digest", "schema"]) | length) == 0 and
              .schema == "ledger-definition-conformance-cases/v3" and
              (.reconstructed_cases_digest |
                type == "string" and test("^sha256:[0-9a-f]{64}$")) and
              (.oracle == null or (
                (.oracle | type == "object") and
                (.oracle | keys | sort) ==
                  ["ledger_version", "skills_zig_commit"] and
                (.oracle.skills_zig_commit |
                  type == "string" and test("^[0-9a-f]{40}$")) and
                (.oracle.ledger_version |
                  type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
              )) and
              (.bases | type == "object" and length > 0) and
              all(.bases[];
                type == "string" and
                startswith("/") == false and
                (split("/") | all(. != "" and . != "." and . != ".."))
              ) and
              (.cases | type == "array" and length > 0) and
              ([.cases[].id] | unique | length) == (.cases | length) and
              all(.cases[];
                type == "object" and
                ((keys - ["base", "expect", "id", "materialization", "remove", "set"]) | length) == 0 and
                (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
                (.base | type == "string") and
                (.expect == "valid" or .expect == "invalid") and
                (.materialization == null or (
                  .expect == "valid" and
                  (.materialization | type == "object") and
                  (.materialization | keys | sort) ==
                    ["artifact_id", "canonical_content_digest"] and
                  (.materialization.artifact_id |
                    type == "string" and test("^sha256:[0-9a-f]{64}$")) and
                  (.materialization.canonical_content_digest |
                    type == "string" and test("^sha256:[0-9a-f]{64}$"))
                ))
              ) and
              all($suite.cases[].base;
                . as $base | $suite.bases | has($base))
            ' \
            "$fixture_suite" >/dev/null
          validate_json_pointer_deltas "$fixture_suite"

          fixture_tmp=$(mktemp -d)
          reconstructed_digests="$fixture_tmp/reconstructed-digests.jsonl"
          : >"$reconstructed_digests"
          while IFS=$'\t' read -r case_id expectation; do
            fixture="$fixture_tmp/$case_id.json"
            reconstruct_definition_case \
              "$fixture_root" \
              "$fixture_suite" \
              "$case_id" \
              "$fixture"
            append_reconstructed_digest \
              "$case_id" \
              "$fixture" \
              "$reconstructed_digests"
            fixture_count=$((fixture_count + 1))

            if [[ "$expectation" == "valid" ]]; then
              "$ledger_bin" validate \
                --definition "$definition" \
                --input "$input_name=$fixture" \
                --format json |
                jq -e \
                  '.valid == true and
                   .authority_granted == false and
                   .storage_mutated == false' >/dev/null

              expected_materialization=$(
                jq -c \
                  --arg case_id "$case_id" \
                  '.cases[] |
                   select(.id == $case_id) |
                   .materialization // empty' \
                  "$fixture_suite"
              )
              if [[ -n "$expected_materialization" ]]; then
                materialization_count=$((materialization_count + 1))
                expected_id=$(jq -r '.artifact_id' <<<"$expected_materialization")
                expected_digest=$(
                  jq -r '.canonical_content_digest' <<<"$expected_materialization"
                )
                identity_pointer=$(jq -r '.identity.field // empty' "$definition")
                if [[ -n "$identity_pointer" ]]; then
                  expected_content=$(
                    jq -S -c \
                      --arg pointer "$identity_pointer" \
                      --arg artifact_id "$expected_id" \
                      '
                        def pointer_path($pointer):
                          if $pointer == "" then
                            []
                          else
                            $pointer |
                            ltrimstr("/") |
                            split("/") |
                            map(gsub("~1"; "/") | gsub("~0"; "~"))
                          end;
                        setpath(pointer_path($pointer); $artifact_id)
                      ' \
                      "$fixture"
                  )
                else
                  expected_content=$(jq -S -c '.' "$fixture")
                fi
                "$ledger_bin" materialize \
                  --definition "$definition" \
                  --input "$input_name=$fixture" \
                  --format json |
                  jq -e \
                    --arg expected_id "$expected_id" \
                    --arg expected_digest "$expected_digest" \
                    --arg expected_content "$expected_content" \
                    '.valid == true and
                     .artifact_id == $expected_id and
                     .canonical_content_digest == $expected_digest and
                     .canonical_content == $expected_content and
                     .authority_granted == false and
                     .storage_mutated == false' >/dev/null
              fi
            else
              set +e
              result=$(
                "$ledger_bin" validate \
                  --definition "$definition" \
                  --input "$input_name=$fixture" \
                  --format json
              )
              status=$?
              set -e
              [[ "$status" -eq 2 ]]
              jq -e \
                '.valid == false and
                 .authority_granted == false and
                 .storage_mutated == false' \
                <<<"$result" >/dev/null
            fi
          done < <(
            jq -r '.cases[] | [.id, .expect] | @tsv' "$fixture_suite"
          )
          verify_reconstructed_digest_set \
            "$reconstructed_digests" \
            "$(jq -r '.reconstructed_cases_digest' "$fixture_suite")" \
            "$fixture_tmp/reconstructed-digest-set.json"
          rm -rf -- "$fixture_tmp"
        fi
        ;;
      *)
        echo "$manifest references a definition outside seq/ or ledger/: $path" >&2
        exit 1
        ;;
    esac
  done < <(jq -r '.seq[], .ledger[] | [.id, .path] | @tsv' "$manifest")
done

plan_policy_definition=codex/skills/plan/definitions/ledger/plan-policy-document.json
plan_policy_fixture="$skills_zig_root/testdata/dotfiles/skill-definitions/plan/fixtures/ledger/execution-policy-graph/bases/complete.json"
plan_id=$(jq -r '.execution_policy_graph.plan_id' "$plan_policy_fixture")
plan_tmp=$(mktemp -d)
plan_repo=$(cd "$plan_tmp" && pwd -P)
create_result=$(
  "$ledger_bin" transact \
    --definition "$plan_policy_definition" \
    --operation create \
    --repo "$plan_repo" \
    --input "policy=$plan_policy_fixture" \
    --param "plan_id=$plan_id" \
    --format json
)
transaction_count=$((transaction_count + 1))
jq -e \
  --arg plan_id "$plan_id" \
  '.schema == "ledger-transaction-result/v1" and
   .definition.id == "plan/plan-policy-document" and
   .definition.abi == "ledger-artifact-abi/v1" and
   .operation == "create" and
   .effects[0].logical_ref == ("plan/" + $plan_id + "/policy.json") and
   (.returned_content | fromjson |
     .execution_policy_graph.plan_id == $plan_id) and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  <<<"$create_result" >/dev/null
created_revision=$(jq -r '.effects[0].revision_after' <<<"$create_result")

project_result=$(
  "$ledger_bin" project \
    --definition "$plan_policy_definition" \
    --projection show \
    --repo "$plan_repo" \
    --param "plan_id=$plan_id" \
    --format json
)
jq -e \
  --arg plan_id "$plan_id" \
  --arg revision "$created_revision" \
  '.schema == "ledger-projection-result/v1" and
   .definition.id == "plan/plan-policy-document" and
   .projection == "show" and
   .store.logical_ref == ("plan/" + $plan_id + "/policy.json") and
   .store.revision == $revision and
   .data.execution_policy_graph.plan_id == $plan_id and
   .authority_granted == false and
   .storage_mutated == false' \
  <<<"$project_result" >/dev/null

set +e
missing_revision_result=$(
  "$ledger_bin" transact \
    --definition "$plan_policy_definition" \
    --operation revise \
    --repo "$plan_repo" \
    --input "policy=$plan_policy_fixture" \
    --param "plan_id=$plan_id" \
    --param request_id=revision-smoke \
    --format json
)
missing_revision_status=$?
set -e
[[ "$missing_revision_status" -eq 2 ]]
jq -e \
  '.schema == "ledger-transaction-error/v1" and
   .code == "MissingOperationParameter" and
   .semantic_authority_granted == false' \
  <<<"$missing_revision_result" >/dev/null

revise_result=$(
  "$ledger_bin" transact \
    --definition "$plan_policy_definition" \
    --operation revise \
    --repo "$plan_repo" \
    --input "policy=$plan_policy_fixture" \
    --param "plan_id=$plan_id" \
    --param request_id=revision-smoke \
    --param "expected_revision=$created_revision" \
    --format json
)
transaction_count=$((transaction_count + 1))
jq -e \
  --arg plan_id "$plan_id" \
  '.schema == "ledger-transaction-result/v1" and
   .definition.id == "plan/plan-policy-document" and
   .operation == "revise" and
   .effects[0].logical_ref == ("plan/" + $plan_id + "/policy.json") and
   .effects[0].result == "replaced" and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  <<<"$revise_result" >/dev/null
rm -rf -- "$plan_tmp"

tune_definition=codex/skills/tune/definitions/ledger/skill-decision-contract.json
while IFS= read -r contract; do
  contract_count=$((contract_count + 1))
  "$ledger_bin" validate \
    --definition "$tune_definition" \
    --input "contract=$contract" \
    --format json |
    jq -e \
      '.valid == true and
       .authority_granted == false and
       .storage_mutated == false' >/dev/null
done < <(
  rg --files codex/skills |
    grep '/references/decision-contract\.json$' |
    LC_ALL=C sort
)

if rg --files codex | grep -q '/decision-contract\.ya\?ml$'; then
  echo "machine-consumed decision-contract YAML remains" >&2
  exit 1
fi
if rg \
  --glob '*.md' \
  --glob '*.yaml' \
  --glob '*.yml' \
  '^[[:space:]]*(plan_source_contract|spec_governance_receipt):' \
  codex >/dev/null
then
  echo "machine-consumed PSC-v1 or SGR-v2 YAML example remains" >&2
  exit 1
fi

actuating_manifest=codex/skills/actuating/definitions/manifest.json
if jq -e \
  '.ledger[] | select(.id == "actuating/evidence-protocol")' \
  "$actuating_manifest" >/dev/null
then
  DOTFILES_ROOT="$dotfiles_root" \
    LEDGER_BIN="$ledger_bin" \
    "$script_dir/check-actuating-evidence-protocol.sh"
fi

if [[ -f codex/skills/memory-source-notes/definitions/ledger/synesthesia-memory-note-payload.json ]]; then
  DOTFILES_ROOT="$dotfiles_root" \
    LEDGER_BIN="$ledger_bin" \
    "$script_dir/check-memory-source-notes.sh"
fi

printf \
  'definition conformance passed: manifests=%d seq=%d ledger=%d fixtures=%d materializations=%d transactions=%d contracts=%d\n' \
  "$manifest_count" \
  "$seq_count" \
  "$ledger_count" \
  "$fixture_count" \
  "$materialization_count" \
  "$transaction_count" \
  "$contract_count"
