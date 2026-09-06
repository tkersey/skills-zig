#!/usr/bin/env bash
set -euo pipefail
binary=$1
fixture=apps/ledger/src/v1/fixtures/relation-definition.json
temp_base=$(cd "${TMPDIR:-/tmp}" && pwd -P)
repo=$(mktemp -d "$temp_base/ledger-relation.XXXXXX")
trap 'rm -rf -- "$repo"' EXIT
definition="$repo/definition.json"
jq '
  .requires.operators += ["limit"] |
  .parameters.target = {type: "string", required: false} |
  .projections.filtered = .projections.blockers |
  .projections.filtered.pipeline += [{op: "filter", path: "/blockers/0", equals: "A"}] |
  .projections.renamed = .projections.blockers |
  .projections.renamed.pipeline[0].relation.unmatched_field = "missing" |
  .projections.renamed.pipeline += [{op: "filter", any: [
    {all: [{path: "/missing/0", equals: "A"}, {path: "/status", equals: "pending"}]},
    {all: [{path: "/id", equals: "absent"}]}
  ]}] |
  .projections.second = .projections.blockers |
  .projections.second.pipeline += [{op: "filter", path: "/blockers/1", param: "target"}] |
  .projections.limited = .projections.filtered |
  .projections.limited.pipeline += [{op: "limit", count: 1}]
' "$fixture" >"$definition"

project() {
  local name=$1
  shift
  "$binary" project --definition "$definition" --repo "$repo" --projection "$name" --format json "$@"
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
project filtered | jq -e '[.data[].id] == ["B"]' >/dev/null
project renamed | jq -e '.data[0].id == "B" and .data[0].missing == ["A"]' >/dev/null
before=$(revision)
if mutate link arc '{"record":{"vertex":"A","target":"B"}}' ab --param "revision=$before" >"$repo/rejected.json"; then
  echo 'cycle was admitted' >&2; exit 1
fi
jq -e '.code == "RelationCycle"' "$repo/rejected.json" >/dev/null
test "$before" = "$(revision)"
mutate satisfy submission '{"id":"A","record":{"title":"Vertex A"}}' done --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["B"]' >/dev/null
project filtered | jq -e '.data == [] and .stats.records_matched == 0' >/dev/null
mutate reset submission '{"id":"A","record":{"title":"Vertex A"}}' reset --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["A"]' >/dev/null
mutate unlink arc '{"record":{"vertex":"B","target":"A"}}' unlink --param "revision=$(revision)" >/dev/null
project eligible | jq -e '[.data[].id] == ["A","B"]' >/dev/null
for id in C D; do
  mutate create submission "{\"id\":\"$id\",\"record\":{\"title\":\"Vertex $id\"}}" "$id" >/dev/null
  mutate link arc "{\"record\":{\"vertex\":\"$id\",\"target\":\"A\"}}" "$id-a" \
    --param "revision=$(revision)" >/dev/null
done
mutate link arc '{"record":{"vertex":"C","target":"B"}}' cb --param "revision=$(revision)" >/dev/null
project second --param target=B | jq -e '.data[0].id == "C" and .data[0].blockers == ["A","B"]' >/dev/null
project second --param target=A | jq -e '.data == []' >/dev/null
project limited | jq -e '[.data[].id] == ["C"] and
  .stats.records_matched == 2 and .stats.records_emitted == 1' >/dev/null
"$binary" doctor --definition "$definition" --repo "$repo" --format json | jq -e '.healthy' >/dev/null
printf '%s\n' 'directed relation native smoke: pass'
