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
      ["cases", "protocol_definition", "reconstructed_candidates_digest", "schema", "sources"] and
    .schema == "actuating-evidence-protocol-cases/v2" and
    (.reconstructed_candidates_digest |
      type == "string" and test("^sha256:[0-9a-f]{64}$")) and
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
        ["candidate", "error", "expect", "id", "patch", "setup"] and
      (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
      (.setup == "accepted-debt" or .setup == "rejected-review") and
      (.candidate == "construction-successor" or
       .candidate == "goal-successor") and
      (.expect == "valid" or .expect == "invalid") and
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

source_suite_index=0
while IFS= read -r source_fixture_root; do
  source_suite_index=$((source_suite_index + 1))
  source_fixture_root="$fixture_sets/$source_fixture_root"
  verify_definition_suite_digest \
    "$source_fixture_root" \
    "$source_fixture_root/cases.json" \
    "$scenario_tmp/source-suite-$source_suite_index"
done < <(jq -r '.sources[].fixture_root' "$scenarios" | LC_ALL=C sort -u)

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

check_structural_facts() {
  local case_tmp=$1
  local repo_root=$2
  local result="$case_tmp/structural-facts.json"
  local payload="$case_tmp/structural-facts-payload.json"
  local expected_head

  "$ledger_bin" project \
    --definition "$protocol_definition" \
    --projection structural-facts \
    --repo "$repo_root" \
    --param goal=goal-1 \
    --format json >"$result"
  expected_head=$(
    tail -n 1 "$repo_root/.ledger/actuation/goal-1/evidence.jsonl" |
      jq -r '.event_digest'
  )
  jq -e \
    --arg head "$expected_head" \
    --slurpfile context "$case_tmp/context.json" \
    '
      .schema == "ledger-projection-result/v1" and
      .definition.id == "actuating/evidence-protocol" and
      .projection == "structural-facts" and
      .data.construction_ref ==
        $context[0].construction_artifact_id and
      .data.counterexample_class_count == 1 and
      .data.event_count == 3 and
      .data.event_kinds.construction_contract_registered == 1 and
      .data.event_kinds.counterexample_set_registered == 1 and
      .data.event_kinds.goal_contract_registered == 1 and
      ([.data.event_kinds[]] | add) == 3 and
      .data.goal_contract_ref == $context[0].goal_artifact_id and
      .data.goal_id == "goal-1" and
      .data.head_digest == $head and
      .data.pending_operation == null and
      .data.subject_digest == $context[0].subject_digest and
      .authority_granted == false and
      .storage_mutated == false
    ' \
    "$result" >/dev/null

  "$ledger_bin" project \
    --definition "$protocol_definition" \
    --projection structural-facts \
    --repo "$repo_root" \
    --param goal=goal-1 \
    --payload-only \
    --format json >"$payload"
  jq -S -c '.data' "$result" | cmp -s - "$payload"
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

check_existing_binding() {
  local binding_tmp="$scenario_tmp/existing-binding"
  local source_tmp="$binding_tmp/source"
  local source_repo="$source_tmp/repo"
  local target_repo="$binding_tmp/target-repo"
  local invalid_repo="$binding_tmp/invalid-repo"
  local source_log
  local target_log
  local invalid_log
  local before_digest
  local after_digest
  local unbound_rc
  local duplicate_rc
  local invalid_rc

  mkdir -p \
    "$source_repo" \
    "$target_repo/.ledger/actuation/goal-1" \
    "$invalid_repo/.ledger/actuation/goal-1"
  source_repo=$(cd "$source_repo" && pwd -P)
  target_repo=$(cd "$target_repo" && pwd -P)
  invalid_repo=$(cd "$invalid_repo" && pwd -P)
  setup_review "$source_tmp" "$source_repo" accepted
  source_log="$source_repo/.ledger/actuation/goal-1/evidence.jsonl"
  target_log="$target_repo/.ledger/actuation/goal-1/evidence.jsonl"
  invalid_log="$invalid_repo/.ledger/actuation/goal-1/evidence.jsonl"
  cp "$source_log" "$target_log"
  jq -c \
    'if .sequence == 1 then .recorded_at = "invalid" else . end' \
    "$source_log" >"$invalid_log"
  before_digest=$(shasum -a 256 "$target_log" | awk '{print $1}')

  set +e
  "$ledger_bin" doctor \
    --definition "$protocol_definition" \
    --repo "$target_repo" \
    --param goal=goal-1 \
    --format json >"$binding_tmp/unbound-doctor.json"
  unbound_rc=$?
  set -e
  [[ "$unbound_rc" -eq 2 ]]
  jq -e \
    '.schema == "ledger-doctor-result/v1" and
     .healthy == false and
     ([.. | objects | .error_code? // empty] |
       index("InvalidStoreBinding") != null)' \
    "$binding_tmp/unbound-doctor.json" >/dev/null

  "$ledger_bin" transact \
    --definition "$protocol_definition" \
    --operation bind-existing \
    --repo "$target_repo" \
    --param goal=goal-1 \
    --format json >"$binding_tmp/binding.json"
  jq -e \
    '.schema == "ledger-transaction-result/v1" and
     .valid == true and
     .operation == "bind-existing" and
     (.effects | length) == 1 and
     .effects[0].slot == "events" and
     .effects[0].logical_ref == "actuation/goal-1/evidence.jsonl" and
     .effects[0].result == "bound" and
     .effects[0].revision_before == .effects[0].revision_after and
     .semantic_authority_granted == false and
     .storage_mutated == true' \
    "$binding_tmp/binding.json" >/dev/null
  after_digest=$(shasum -a 256 "$target_log" | awk '{print $1}')
  [[ "$before_digest" == "$after_digest" ]]
  check_structural_facts "$source_tmp" "$target_repo"

  set +e
  "$ledger_bin" transact \
    --definition "$protocol_definition" \
    --operation bind-existing \
    --repo "$target_repo" \
    --param goal=goal-1 \
    --format json >"$binding_tmp/duplicate-binding.json"
  duplicate_rc=$?
  set -e
  [[ "$duplicate_rc" -eq 2 ]]
  jq -e \
    '.schema == "ledger-transaction-error/v1" and
     .code == "StoreAlreadyBound" and
     .semantic_authority_granted == false and
     .storage_mutated == false' \
    "$binding_tmp/duplicate-binding.json" >/dev/null
  [[ "$before_digest" == "$(shasum -a 256 "$target_log" | awk '{print $1}')" ]]

  set +e
  "$ledger_bin" transact \
    --definition "$protocol_definition" \
    --operation bind-existing \
    --repo "$invalid_repo" \
    --param goal=goal-1 \
    --format json >"$binding_tmp/invalid-binding.json"
  invalid_rc=$?
  set -e
  [[ "$invalid_rc" -eq 2 ]]
  jq -e \
    '.schema == "ledger-transaction-error/v1" and
     .code == "InvalidEventUnixTimestamp" and
     .semantic_authority_granted == false and
     .storage_mutated == false' \
    "$binding_tmp/invalid-binding.json" >/dev/null
  [[ ! -d "$invalid_repo/.ledger/.bindings" ]] ||
    [[ -z "$(find "$invalid_repo/.ledger/.bindings" -type f -print -quit)" ]]
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
candidate_digests="$scenario_tmp/reconstructed-candidate-digests.jsonl"
: >"$candidate_digests"
while IFS=$'\t' read -r case_id setup candidate_kind expectation expected_error; do
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
  check_structural_facts "$case_tmp" "$repo_root"
  prepare_candidate "$case_id" "$candidate_kind" "$case_tmp"
  append_reconstructed_digest \
    "$case_id" \
    "$case_tmp/candidate.json" \
    "$candidate_digests"
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
     [.id, .setup, .candidate, .expect, (.error // "-")] |
     @tsv' \
    "$scenarios"
)

verify_reconstructed_digest_set \
  "$candidate_digests" \
  "$(jq -r '.reconstructed_candidates_digest' "$scenarios")" \
  "$scenario_tmp/reconstructed-candidate-digest-set.json"

check_existing_binding

printf \
  'actuating Evidence protocol scenarios passed: cases=%d bindings=1\n' \
  "$case_count"
