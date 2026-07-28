#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
bin_path=${1:-"$root_dir/zig-out/bin/seq"}

if [[ ! -x "$bin_path" ]]; then
  echo "binary not found or executable: $bin_path" >&2
  exit 1
fi

expected=$'definition check\ndefinition describe\nobserve\nexplain\nsessions\nturns\nsession-detail\ntool-lifecycle\nsession-graph\ntail\nfind-session\ndatasets\ndataset-schema\nquery\nindex\ncapabilities\nversion'
help_output=$("$bin_path" --help)
actual=$(
  sed -n \
    '/^commands:$/,/^$/ {
      s/^  //
      /^commands:$/d
      /^$/d
      p
    }' \
    <<<"$help_output"
)

if [[ "$actual" != "$expected" ]]; then
  echo "Seq 1.0 command surface mismatch" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

capabilities=$("$bin_path" capabilities --format json)
jq -e \
  '
    .schema == "seq-capabilities/v1" and
    .version == "1.0.0" and
    (.observation_abis | index("seq-observation-abi/v1")) != null and
    (.source_adapters | type == "array" and length > 0) and
    (.operators | type == "array" and length > 0) and
    (.renderers | type == "array" and length > 0) and
    .cache_format != null and
    (.limits | type == "object")
  ' \
  <<<"$capabilities" >/dev/null

for forbidden in \
  actuation \
  universalist \
  review-compiler \
  decision-capsule \
  execution-policy \
  learnings \
  negative-ledger \
  synesthesia \
  skill-decision
do
  if grep -F -- "$forbidden" <<<"$help_output$capabilities" >/dev/null; then
    echo "Seq 1.0 exposes domain vocabulary: $forbidden" >&2
    exit 1
  fi
done

echo "Seq 1.0 command-surface gate passed for $bin_path"
