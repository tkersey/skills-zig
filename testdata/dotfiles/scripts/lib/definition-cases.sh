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
  local expected_digest
  local actual_digest
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

  expected_digest=$(
    jq -r \
      --arg case_id "$case_id" \
      '.cases[] | select(.id == $case_id) | .fixture_digest' \
      "$fixture_suite"
  )
  actual_digest="sha256:$(shasum -a 256 "$output" | awk '{print $1}')"
  [[ "$actual_digest" == "$expected_digest" ]]
}
