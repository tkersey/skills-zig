#!/usr/bin/env bash
set -euo pipefail
binary=$1
definition=apps/ledger/src/v1/fixtures/relation-definition.json
repo=$(mktemp -d "${TMPDIR:-/tmp}/ledger-relation.XXXXXX")
trap 'rm -rf -- "$repo"' EXIT

project() {
  "$binary" project --definition "$definition" --repo "$repo" --projection "$1" --format json
}
mutate() {
  local operation=$1 input=$2 payload=$3 request=$4
  shift 4
  printf '%s' "$payload" | "$binary" transact --definition "$definition" --repo "$repo" \
    --operation "$operation" --input "$input=-" --param "request=$request" --format json "$@"
}
revision() { project current | jq -r '.store.revision'; }

"$binary" definition check --definition "$definition" --format json | jq -e '.valid' >/dev/null
mutate create submission '{"id":"A","record":{"title":"Vertex A"}}' a >/dev/null
mutate create submission '{"id":"B","record":{"title":"Vertex B"}}' b >/dev/null
mutate link arc '{"record":{"vertex":"B","target":"A"}}' ba --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["A"]' >/dev/null
project blockers | jq -e '.data[0].blockers == ["A"]' >/dev/null
before=$(revision)
if mutate link arc '{"record":{"vertex":"A","target":"B"}}' ab --param "revision=$before" >"$repo/rejected.json"; then
  echo 'cycle was admitted' >&2; exit 1
fi
jq -e '.code == "RelationCycle"' "$repo/rejected.json" >/dev/null
test "$before" = "$(revision)"
mutate satisfy submission '{"id":"A","record":{"title":"Vertex A"}}' done --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["B"]' >/dev/null
mutate reset submission '{"id":"A","record":{"title":"Vertex A"}}' reset --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["A"]' >/dev/null
mutate unlink arc '{"record":{"vertex":"B","target":"A"}}' unlink --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["A","B"]' >/dev/null
"$binary" doctor --definition "$definition" --repo "$repo" --format json | jq -e '.healthy' >/dev/null
printf '%s\n' 'directed relation native smoke: pass'
