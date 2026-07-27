#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"

dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
ledger_bin=${LEDGER_BIN:-ledger}
fixture_sets="$skills_zig_root/testdata/dotfiles/skill-definitions"
scenarios=$(
  cd "$fixture_sets/actuating/fixtures/ledger/evidence-protocol" &&
    pwd -P
)/scenarios.json
protocol_definition=$(
  jq -r '.protocol_definition' "$scenarios"
)
protocol_definition="$dotfiles_root/$protocol_definition"

command -v jq >/dev/null
command -v "$ledger_bin" >/dev/null

jq -e \
  '
    type == "object" and
    (keys | sort) ==
      ["cases", "protocol_definition", "schema", "sources"] and
    .schema == "actuating-evidence-protocol-cases/v1" and
    (.protocol_definition |
      type == "string" and
      startswith("/") == false and
      (split("/") | all(. != "" and . != "." and . != ".."))) and
    (.sources | type == "object" and length == 4) and
    all(.sources[];
      type == "object" and
      (keys | sort) ==
        ["case", "definition", "fixture_root", "input"] and
      all(.case, .input;
        type == "string" and test("^[A-Za-z0-9._-]+$")) and
      all(.definition, .fixture_root;
        type == "string" and
        startswith("/") == false and
        (split("/") | all(. != "" and . != "." and . != ".."))
      )
    ) and
    (.cases | type == "array" and length > 0) and
    ([.cases[].id] | unique | length) == (.cases | length) and
    all(.cases[];
      type == "object" and
      (keys | sort) ==
        ["candidate", "candidate_digest", "error", "expect", "id", "patch", "setup"] and
      (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
      (.setup == "accepted-debt" or .setup == "rejected-review") and
      (.candidate == "construction-successor" or
       .candidate == "goal-successor") and
      (.expect == "valid" or .expect == "invalid") and
      (.candidate_digest |
        type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      ((.expect == "valid" and .error == null) or
       (.expect == "invalid" and
        (.error | type == "string" and length > 0))) and
      (.patch | type == "array") and
      all(.patch[];
        type == "object" and
        (.path |
          type == "string" and
          test("^/(?:[^~/]|~[01])+(?:/(?:[^~/]|~[01])+)*$")) and
        (
          (.op == "remove" and
            (keys | sort) == ["op", "path"]) or
          ((.op == "add" or .op == "replace") and
            (keys | sort) == ["op", "path", "value"])
        )
      )
    )
  ' \
  "$scenarios" >/dev/null

[[ -f "$protocol_definition" && ! -L "$protocol_definition" ]]
"$ledger_bin" definition check \
  --definition "$protocol_definition" \
  --format json |
  jq -e '.valid == true and .authority_granted == false' >/dev/null

scenario_tmp=$(mktemp -d)
cleanup_scenario_tmp() {
  if [[ -n ${scenario_tmp:-} && -d "$scenario_tmp" ]]; then
    rm -rf -- "$scenario_tmp"
  fi
}
trap cleanup_scenario_tmp EXIT

source_value() {
  local source_name=$1
  local field=$2
  jq -r --arg source "$source_name" --arg field "$field" \
    '.sources[$source][$field]' "$scenarios"
}

reconstruct_source() {
  local source_name=$1
  local output=$2
  local fixture_root
  local fixture_suite
  local case_id

  fixture_root="$fixture_sets/$(source_value "$source_name" fixture_root)"
  fixture_suite="$fixture_root/cases.json"
  case_id=$(source_value "$source_name" case)
  [[ -f "$fixture_suite" && ! -L "$fixture_suite" ]]
  reconstruct_definition_case \
    "$fixture_root" \
    "$fixture_suite" \
    "$case_id" \
    "$output"
}

materialize_source() {
  local source_name=$1
  local source_document=$2
  local result=$3
  local definition
  local input_name

  definition="$dotfiles_root/$(source_value "$source_name" definition)"
  input_name=$(source_value "$source_name" input)
  [[ -f "$definition" && ! -L "$definition" ]]
  "$ledger_bin" materialize \
    --definition "$definition" \
    --input "$input_name=$source_document" \
    --format json >"$result"
  jq -e \
    '.valid == true and
     .authority_granted == false and
     .storage_mutated == false' \
    "$result" >/dev/null
}

transact_success() {
  local operation=$1
  local input_name=$2
  local input_document=$3
  local repo_root=$4
  local result=$5

  "$ledger_bin" transact \
    --definition "$protocol_definition" \
    --operation "$operation" \
    --repo "$repo_root" \
    --input "$input_name=$input_document" \
    --param goal=goal-1 \
    --format json >"$result"
  jq -e \
    '.schema == "ledger-transaction-result/v1" and
     .valid == true and
     .semantic_authority_granted == false and
     .storage_mutated == true' \
    "$result" >/dev/null
}

setup_review() {
  local case_tmp=$1
  local repo_root=$2
  local review_status=$3
  local goal_source="$case_tmp/goal-source.json"
  local goal_result="$case_tmp/goal-result.json"
  local goal_request="$case_tmp/goal-request.json"
  local construction_source="$case_tmp/construction-source.json"
  local construction_bound="$case_tmp/construction-bound.json"
  local construction_result="$case_tmp/construction-result.json"
  local construction_request="$case_tmp/construction-request.json"
  local counterexample_source="$case_tmp/counterexample-source.json"
  local counterexample_bound="$case_tmp/counterexample-bound.json"
  local counterexample_result="$case_tmp/counterexample-result.json"
  local counterexample_request="$case_tmp/counterexample-request.json"
  local goal_artifact_id
  local construction_artifact_id
  local counterexample_artifact_id
  local subject_digest

  reconstruct_source initial-goal "$goal_source"
  materialize_source initial-goal "$goal_source" "$goal_result"
  goal_artifact_id=$(jq -r '.artifact_id' "$goal_result")
  jq -n \
    --slurpfile materialized "$goal_result" \
    '{
      schema: "actuating-goal-registration/v1",
      goal_id: "goal-1",
      body: ($materialized[0].canonical_content | fromjson)
    }' >"$goal_request"
  transact_success \
    register-goal \
    goal_registration \
    "$goal_request" \
    "$repo_root" \
    "$case_tmp/goal-transaction.json"

  reconstruct_source initial-construction "$construction_source"
  jq -S -c \
    --arg goal "$goal_artifact_id" \
    '.artifact.artifact_id = null |
     .artifact.payload.goal_contract_ref = $goal' \
    "$construction_source" >"$construction_bound"
  materialize_source \
    initial-construction \
    "$construction_bound" \
    "$construction_result"
  construction_artifact_id=$(jq -r '.artifact_id' "$construction_result")
  subject_digest=$(
    jq -r \
      '.canonical_content |
       fromjson |
       .artifact.payload.subject.base_artifact_digest' \
      "$construction_result"
  )
  jq -n \
    --arg construction "$construction_artifact_id" \
    --arg subject "$subject_digest" \
    --slurpfile materialized "$construction_result" \
    '{
      schema: "actuating-construction-registration/v1",
      goal_id: "goal-1",
      construction_ref: $construction,
      subject_digest: $subject,
      body: ($materialized[0].canonical_content | fromjson)
    }' >"$construction_request"
  transact_success \
    register-construction \
    construction_registration \
    "$construction_request" \
    "$repo_root" \
    "$case_tmp/construction-transaction.json"

  reconstruct_source accepted-counterexample "$counterexample_source"
  jq -S -c \
    --arg construction "$construction_artifact_id" \
    --arg subject "$subject_digest" \
    --arg status "$review_status" \
    '
      .artifact.artifact_id = null |
      .artifact.goal_id = "goal-1" |
      .artifact.payload.subject.repository = "repo" |
      .artifact.payload.subject.construction_ref = $construction |
      .artifact.payload.subject.artifact_digest = $subject |
      .artifact.payload.classes[0].class_id = "class-1" |
      .artifact.payload.classes[0].law_ref = "law-1" |
      .artifact.payload.classes[0].owner_boundary = "owner" |
      .artifact.payload.classes[0].status = $status
    ' \
    "$counterexample_source" >"$counterexample_bound"
  materialize_source \
    accepted-counterexample \
    "$counterexample_bound" \
    "$counterexample_result"
  counterexample_artifact_id=$(jq -r '.artifact_id' "$counterexample_result")
  jq -n \
    --arg construction "$construction_artifact_id" \
    --arg subject "$subject_digest" \
    --slurpfile materialized "$counterexample_result" \
    '{
      schema: "actuating-counterexample-registration/v1",
      goal_id: "goal-1",
      construction_ref: $construction,
      subject_digest: $subject,
      body: ($materialized[0].canonical_content | fromjson)
    }' >"$counterexample_request"
  transact_success \
    register-counterexamples \
    counterexample_registration \
    "$counterexample_request" \
    "$repo_root" \
    "$case_tmp/counterexample-transaction.json"

  jq -n \
    --arg goal "$goal_artifact_id" \
    --arg construction "$construction_artifact_id" \
    --arg counterexamples "$counterexample_artifact_id" \
    --arg subject "$subject_digest" \
    '{
      goal_artifact_id: $goal,
      construction_artifact_id: $construction,
      counterexample_artifact_id: $counterexamples,
      subject_digest: $subject
    }' >"$case_tmp/context.json"
}

prepare_candidate() {
  local case_id=$1
  local candidate_kind=$2
  local case_tmp=$3
  local source_document="$case_tmp/candidate-source.json"
  local bound_document="$case_tmp/candidate-bound.json"
  local candidate_document="$case_tmp/candidate.json"
  local patch

  patch=$(
    jq -c --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .patch' \
      "$scenarios"
  )
  if [[ "$candidate_kind" == "construction-successor" ]]; then
    reconstruct_source successor-construction "$source_document"
    jq -S -c \
      --slurpfile context "$case_tmp/context.json" \
      '
        .artifact.artifact_id = null |
        .artifact.predecessor_refs =
          [$context[0].construction_artifact_id] |
        .artifact.payload.goal_contract_ref =
          $context[0].goal_artifact_id |
        .artifact.payload.subject.base_artifact_digest =
          $context[0].subject_digest |
        .artifact.payload.counterexample_class_refs = ["class-1"] |
        .artifact.payload.recompilation.evaluated_class_refs = ["class-1"] |
        .artifact.payload.recompilation.counterexample_set_ref =
          $context[0].counterexample_artifact_id
      ' \
      "$source_document" >"$bound_document"
  else
    reconstruct_source initial-goal "$source_document"
    jq -S -c \
      --slurpfile context "$case_tmp/context.json" \
      '
        .artifact.artifact_id = null |
        .artifact.predecessor_refs = [$context[0].goal_artifact_id] |
        .artifact.payload.objective.required_outcomes =
          ["law holds after successor"]
      ' \
      "$source_document" >"$bound_document"
  fi
  apply_json_patch_document "$bound_document" "$patch" "$candidate_document"
}

run_candidate() {
  local case_id=$1
  local candidate_kind=$2
  local case_tmp=$3
  local repo_root=$4
  local candidate_document="$case_tmp/candidate.json"
  local candidate_result="$case_tmp/candidate-result.json"
  local candidate_request="$case_tmp/candidate-request.json"
  local operation
  local input_name
  local source_name
  local candidate_artifact_id
  local subject_digest

  if [[ "$candidate_kind" == "construction-successor" ]]; then
    source_name=successor-construction
    operation=register-construction
    input_name=construction_registration
  else
    source_name=initial-goal
    operation=register-goal
    input_name=goal_registration
  fi
  materialize_source "$source_name" "$candidate_document" "$candidate_result"
  candidate_artifact_id=$(jq -r '.artifact_id' "$candidate_result")
  subject_digest=$(jq -r '.subject_digest' "$case_tmp/context.json")
  if [[ "$candidate_kind" == "construction-successor" ]]; then
    jq -n \
      --arg construction "$candidate_artifact_id" \
      --arg subject "$subject_digest" \
      --slurpfile materialized "$candidate_result" \
      '{
        schema: "actuating-construction-registration/v1",
        goal_id: "goal-1",
        construction_ref: $construction,
        subject_digest: $subject,
        body: ($materialized[0].canonical_content | fromjson)
      }' >"$candidate_request"
  else
    jq -n \
      --slurpfile materialized "$candidate_result" \
      '{
        schema: "actuating-goal-registration/v1",
        goal_id: "goal-1",
        body: ($materialized[0].canonical_content | fromjson)
      }' >"$candidate_request"
  fi

  printf '%s\t%s\t%s\n' \
    "$operation" \
    "$input_name" \
    "$candidate_request"
}

case_count=0
while IFS=$'\t' read -r case_id setup candidate_kind expectation expected_error expected_digest; do
  case_count=$((case_count + 1))
  case_tmp="$scenario_tmp/$case_id"
  repo_root="$case_tmp/repo"
  mkdir -p "$repo_root"
  repo_root=$(cd "$repo_root" && pwd -P)

  review_status=accepted
  if [[ "$setup" == "rejected-review" ]]; then
    review_status=rejected
  fi
  setup_review "$case_tmp" "$repo_root" "$review_status"
  prepare_candidate "$case_id" "$candidate_kind" "$case_tmp"
  actual_digest="sha256:$(shasum -a 256 "$case_tmp/candidate.json" | awk '{print $1}')"
  if [[ "$actual_digest" != "$expected_digest" ]]; then
    echo "$case_id candidate digest: $actual_digest" >&2
    if [[ ${REPORT_CANDIDATE_DIGESTS:-0} != 1 ]]; then
      exit 1
    fi
  fi
  IFS=$'\t' read -r operation input_name candidate_request < <(
    run_candidate "$case_id" "$candidate_kind" "$case_tmp" "$repo_root"
  )
  event_log="$repo_root/.ledger/actuation/goal-1/evidence.jsonl"
  before_digest=$(shasum -a 256 "$event_log" | awk '{print $1}')

  set +e
  "$ledger_bin" transact \
    --definition "$protocol_definition" \
    --operation "$operation" \
    --repo "$repo_root" \
    --input "$input_name=$candidate_request" \
    --param goal=goal-1 \
    --format json >"$case_tmp/candidate-transaction.json"
  tx_rc=$?
  set -e
  after_digest=$(shasum -a 256 "$event_log" | awk '{print $1}')

  if [[ "$expectation" == "valid" ]]; then
    [[ "$tx_rc" -eq 0 ]]
    jq -e \
      '.schema == "ledger-transaction-result/v1" and
       .valid == true and
       .semantic_authority_granted == false and
       .storage_mutated == true' \
      "$case_tmp/candidate-transaction.json" >/dev/null
    [[ "$before_digest" != "$after_digest" ]]
  else
    [[ "$tx_rc" -eq 2 ]]
    jq -e \
      --arg error "$expected_error" \
      '.schema == "ledger-transaction-error/v1" and
       .code == $error and
       .semantic_authority_granted == false and
       .storage_mutated == false and
       .storage_mutation_state == "known"' \
      "$case_tmp/candidate-transaction.json" >/dev/null
    [[ "$before_digest" == "$after_digest" ]]
  fi
done < <(
  jq -r \
    '.cases[] |
     [.id, .setup, .candidate, .expect, (.error // "-"), .candidate_digest] |
     @tsv' \
    "$scenarios"
)

printf 'actuating Evidence protocol scenarios passed: cases=%d\n' "$case_count"
