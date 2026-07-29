#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <definitions-root>" >&2
  exit 64
fi

definition_root=$(cd "$1" && pwd -P)
seq_bin=${SEQ_BIN:-seq}
ledger_bin=${LEDGER_BIN:-ledger}

command -v jq >/dev/null
command -v "$seq_bin" >/dev/null
command -v "$ledger_bin" >/dev/null

if [[ -n "$(find "$definition_root" \
  -path '*/definitions/manifest.json' \
  -type l \
  -print \
  -quit)" ]]
then
  echo "definition manifest must be a regular file" >&2
  exit 1
fi

temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
results_file=$(mktemp "$temp_base/definition-loadability.XXXXXX")
trap 'rm -f -- "$results_file"' EXIT

manifest_count=0
seq_count=0
ledger_count=0

while IFS= read -r manifest; do
  manifest_count=$((manifest_count + 1))
  definition_dir=${manifest%/manifest.json}
  owner_dir=${definition_dir%/definitions}
  expected_skill=${owner_dir##*/}

  jq -e \
    --arg expected_skill "$expected_skill" \
    '
      type == "object" and
      (keys | sort) == ["ledger", "schema", "seq", "skill"] and
      .schema == "skill-definition-set/v1" and
      .skill == $expected_skill and
      (.seq | type == "array") and
      (.ledger | type == "array") and
      (
        .seq +
        .ledger
      ) as $references |
      all($references[];
        type == "object" and
        (keys | sort) == ["id", "path"] and
        (.id | type == "string" and length > 0) and
        (.path | type == "string" and length > 0) and
        (.path | startswith("/") | not) and
        (.path | split("/") | all(. != "" and . != "." and . != "..")) and
        (.path | endswith(".json"))
      ) and
      ([.seq[].path] | all(.[]; startswith("seq/"))) and
      ([.ledger[].path] | all(.[]; startswith("ledger/"))) and
      ([$references[].id] | unique | length) ==
        ($references | length) and
      ([$references[].path] | unique | length) ==
        ($references | length)
    ' \
    "$manifest" >/dev/null

  while IFS=$'\t' read -r runtime definition_id relative_path; do
    definition="$definition_dir/$relative_path"
    if [[ ! -f "$definition" || -L "$definition" ]]; then
      echo "manifest reference must resolve to a regular file: $relative_path" >&2
      exit 1
    fi

    case "$runtime" in
      seq)
        binary=$seq_bin
        expected_schema=seq-definition-check-result/v1
        seq_count=$((seq_count + 1))
        ;;
      ledger)
        binary=$ledger_bin
        expected_schema=ledger-definition-check-result/v1
        ledger_count=$((ledger_count + 1))
        ;;
      *)
        echo "unknown definition runtime: $runtime" >&2
        exit 1
        ;;
    esac

    result=$(
      "$binary" definition check \
        --definition "$definition" \
        --format json
    )
    jq -e \
      --arg expected_schema "$expected_schema" \
      --arg definition_id "$definition_id" \
      '
        .schema == $expected_schema and
        .definition.id == $definition_id and
        .valid == true and
        .passive == true and
        .authority_granted == false
      ' \
      <<<"$result" >/dev/null
    jq -c \
      --arg runtime "$runtime" \
      '{
        runtime: $runtime,
        id: .definition.id,
        digest: .definition.digest,
        abi: .definition.abi
      }' \
      <<<"$result" >>"$results_file"
  done < <(
    jq -r \
      '(.seq[] | ["seq", .id, .path]),
       (.ledger[] | ["ledger", .id, .path]) |
       @tsv' \
      "$manifest"
  )
done < <(
  find "$definition_root" \
    -path '*/definitions/manifest.json' \
    -type f \
    -print |
    LC_ALL=C sort
)

if [[ "$manifest_count" -eq 0 ]]; then
  echo "no definition manifests found under $definition_root" >&2
  exit 1
fi

jq -s \
  --argjson manifests "$manifest_count" \
  --argjson seq "$seq_count" \
  --argjson ledger "$ledger_count" \
  --arg seq_version "$("$seq_bin" version)" \
  --arg ledger_version "$("$ledger_bin" version)" \
  '
    {
      schema: "definition-loadability-report/v1",
      binaries: {
        seq: $seq_version,
        ledger: $ledger_version
      },
      counts: {
        manifests: $manifests,
        seq: $seq,
        ledger: $ledger
      },
      definitions: sort_by(.runtime, .id)
    }
  ' \
  "$results_file"
