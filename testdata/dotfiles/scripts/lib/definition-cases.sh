#!/usr/bin/env bash

apply_json_patch_document() {
  local input=$1
  local patch=$2
  local output=$3

  jq -S -c \
    --argjson patch "$patch" \
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
      reduce $patch[] as $operation (.;
        (pointer_path($operation.path)) as $path |
        if $operation.op == "remove" then
          delpaths([$path])
        else
          setpath($path; $operation.value)
        end
      )
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
  local patch

  base_id=$(
    jq -r \
      --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .base' \
      "$fixture_suite"
  )
  base_relative=$(jq -r --arg base "$base_id" '.bases[$base]' "$fixture_suite")
  base_fixture="$fixture_root/$base_relative"
  [[ -f "$base_fixture" && ! -L "$base_fixture" ]]

  patch=$(
    jq -c \
      --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .patch // []' \
      "$fixture_suite"
  )
  apply_json_patch_document "$base_fixture" "$patch" "$output"
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
