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
      all(.cases[];
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

reconstruct_definition_case() {
  local fixture_root=$1
  local fixture_suite=$2
  local case_id=$3
  local output=$4
  local base_id
  local base_relative
  local base_fixture
  local set_values
  local remove_paths

  base_id=$(
    jq -r \
      --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .base' \
      "$fixture_suite"
  )
  base_relative=$(jq -r --arg base "$base_id" '.bases[$base]' "$fixture_suite")
  base_fixture="$fixture_root/$base_relative"
  [[ -f "$base_fixture" && ! -L "$base_fixture" ]]

  set_values=$(
    jq -c \
      --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .set // {}' \
      "$fixture_suite"
  )
  remove_paths=$(
    jq -c \
      --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .remove // []' \
      "$fixture_suite"
  )
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
  done < <(jq -r '.cases[].id' "$fixture_suite")
  expected=$(jq -r '.reconstructed_cases_digest' "$fixture_suite")
  verify_reconstructed_digest_set \
    "$rows" \
    "$expected" \
    "$scratch/reconstructed-digest-set.json"
}
