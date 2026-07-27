#!/usr/bin/env bash

validate_json_pointer_deltas() {
  local suite=$1

  jq -e \
    '
      def valid_pointer:
        type == "string" and
        test("^/(?:[^~/]|~[01])+(?:/(?:[^~/]|~[01])+)*$");
      def unambiguous_pointers($paths):
        all(range(0; ($paths | length)); . as $left |
          all(range($left + 1; ($paths | length)); . as $right |
            ($paths[$left] != $paths[$right]) and
            ($paths[$right] |
              startswith($paths[$left] + "/") | not) and
            ($paths[$left] |
              startswith($paths[$right] + "/") | not)
          )
        );
      [
        ((.valid // {}) | to_entries[] | .value),
        ((.invalid // {}) | to_entries[] | .value)
      ] as $variants |
      all($variants[];
        (.set // {} | type == "object") and
        all((.set // {}) | keys[]; valid_pointer) and
        (.remove // [] | type == "array") and
        all((.remove // [])[]; valid_pointer) and
        unambiguous_pointers(
          (((.set // {}) | keys) + (.remove // [])))
      )
    ' \
    "$suite" >/dev/null
}

apply_json_pointer_delta() {
  local input=$1
  local set_values=$2
  local remove_paths=$3
  local output=$4

  jq -S -c \
    --argjson set_values "$set_values" \
    --argjson remove_paths "$remove_paths" \
    '
      def pointer_path($pointer):
        $pointer |
        ltrimstr("/") |
        split("/") |
        map(
          gsub("~1"; "/") |
          gsub("~0"; "~") |
          if test("^(0|[1-9][0-9]*)$") then
            tonumber
          else
            .
          end
        );
      reduce ($set_values | to_entries | sort_by(.key)[]) as $entry (.;
        setpath(pointer_path($entry.key); $entry.value)
      ) |
      delpaths($remove_paths | sort | map(pointer_path(.)))
    ' \
    "$input" >"$output"
}

materialize_definition_suite() {
  local fixture_root=$1
  local source_suite=$2
  local output_suite=$3
  local scratch=$4
  local base_root="$fixture_root/bases"
  local base_rows="$scratch/base-ids.jsonl"
  local base_ids="$scratch/base-ids.json"
  local base_fixture
  local relative
  local base_id

  [[ -d "$base_root" && ! -L "$base_root" ]]
  : >"$base_rows"
  while IFS= read -r base_fixture; do
    [[ -f "$base_fixture" && ! -L "$base_fixture" ]]
    relative=${base_fixture#"$base_root/"}
    [[ "$relative" != */* && "$relative" == *.json ]]
    base_id=${relative%.json}
    [[ "$base_id" =~ ^[A-Za-z0-9._-]+$ ]]
    jq -nc --arg id "$base_id" '$id' >>"$base_rows"
  done < <(rg --files "$base_root" -g '*.json' | LC_ALL=C sort)
  [[ -s "$base_rows" ]]
  jq -s '.' "$base_rows" >"$base_ids"
  jq --slurpfile bases "$base_ids" \
    '. + {bases: $bases[0]}' \
    "$source_suite" >"$output_suite"
}

definition_suite_case_rows() {
  local suite=$1

  jq -r \
    '
      (.bases[] | [., "valid"]),
      (((.valid // {}) | keys[]) | [., "valid"]),
      (((.invalid // {}) | keys[]) | [., "invalid"]) |
      @tsv
    ' \
    "$suite"
}

definition_suite_case_spec() {
  local suite=$1
  local case_id=$2

  jq -c \
    --arg case_id "$case_id" \
    '
      . as $suite |
      if ($suite.bases | index($case_id)) != null then
        {
          id: $case_id,
          base: $case_id,
          set: {},
          remove: []
        }
      else
        (
          ($suite.valid // {})[$case_id] //
          ($suite.invalid // {})[$case_id] //
          error("unknown conformance case")
        ) as $case |
        {
          id: $case_id
        } + $case + {
          base: (
            $case.base //
            if ($suite.bases | length) == 1 then
              $suite.bases[0]
            else
              error("case requires an explicit base")
            end
          ),
          set: ($case.set // {}),
          remove: ($case.remove // [])
        }
      end
    ' \
    "$suite"
}

reconstruct_definition_case() {
  local fixture_root=$1
  local fixture_suite=$2
  local case_id=$3
  local output=$4
  local case_spec
  local base_id
  local base_fixture
  local set_values
  local remove_paths

  case_spec=$(definition_suite_case_spec "$fixture_suite" "$case_id")
  base_id=$(jq -r '.base' <<<"$case_spec")
  base_fixture="$fixture_root/bases/$base_id.json"
  [[ -f "$base_fixture" && ! -L "$base_fixture" ]]

  set_values=$(jq -c '.set' <<<"$case_spec")
  remove_paths=$(jq -c '.remove' <<<"$case_spec")
  apply_json_pointer_delta \
    "$base_fixture" \
    "$set_values" \
    "$remove_paths" \
    "$output"
}

append_reconstructed_digest() {
  local case_id=$1
  local reconstructed=$2
  local rows=$3
  local digest

  digest="sha256:$(shasum -a 256 "$reconstructed" | awk '{print $1}')"
  jq -nc \
    --arg id "$case_id" \
    --arg digest "$digest" \
    '{id: $id, digest: $digest}' >>"$rows"
}

verify_reconstructed_digest_set() {
  local rows=$1
  local expected=$2
  local payload=$3
  local actual

  jq -s -S -c 'sort_by(.id)' "$rows" >"$payload"
  actual="sha256:$(shasum -a 256 "$payload" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]]
}

verify_definition_suite_digest() {
  local fixture_root=$1
  local fixture_suite=$2
  local scratch=$3
  local case_id
  local reconstructed
  local rows
  local expected

  mkdir -p "$scratch"
  rows="$scratch/reconstructed-digests.jsonl"
  : >"$rows"
  while IFS= read -r case_id; do
    reconstructed="$scratch/$case_id.json"
    reconstruct_definition_case \
      "$fixture_root" \
      "$fixture_suite" \
      "$case_id" \
      "$reconstructed"
    append_reconstructed_digest "$case_id" "$reconstructed" "$rows"
  done < <(definition_suite_case_rows "$fixture_suite" | cut -f1)
  expected=$(jq -r '.reconstructed_cases_digest' "$fixture_suite")
  verify_reconstructed_digest_set \
    "$rows" \
    "$expected" \
    "$scratch/reconstructed-digest-set.json"
}

assert_ledger_doctor_slot_state() {
  local ledger_bin=$1
  local definition=$2
  local repo=$3
  local slot_name=$4
  local expected_state=$5
  local expected_healthy=$6
  local expected_exit=$7
  local output=$8
  local doctor_exit

  set +e
  "$ledger_bin" doctor \
    --definition "$definition" \
    --repo "$repo" \
    --format json >"$output"
  doctor_exit=$?
  set -e
  [[ "$doctor_exit" -eq "$expected_exit" ]]
  jq -e \
    --arg slot_name "$slot_name" \
    --arg expected_state "$expected_state" \
    --argjson expected_healthy "$expected_healthy" \
    '.schema == "ledger-doctor-result/v1" and
     .healthy == $expected_healthy and
     .authority_granted == false and
     .storage_mutated == false and
     any(.slots[];
       .name == $slot_name and
       .status == $expected_state and
       .healthy == $expected_healthy)' \
    "$output" >/dev/null
}
