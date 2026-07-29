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
  awk '
    / commands:$/ { in_section = 1; next }
    /^$/ { in_section = 0; next }
    in_section && /^  [^ ]/ {
      line = substr($0, 3)
      sub(/^seq /, "", line)
      count = split(line, words, /[[:space:]]+/)
      if (words[1] == "definition" && count >= 2) {
        print words[1] " " words[2]
      } else {
        print words[1]
      }
    }
  ' \
    <<<"$help_output"
)

if [[ "$actual" != "$expected" ]]; then
  echo "Seq 1.0 command surface mismatch" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

capabilities=$("$bin_path" capabilities --format json)
version=$(tr -d '[:space:]' < "$root_dir/apps/seq/VERSION")
jq -e --arg version "$version" \
  '
    .schema == "seq-capabilities/v1" and
    .version == $version and
    (.observation_abis | index("seq-observation-abi/v1")) != null and
    (.source_adapters | type == "array" and length > 0) and
    (.operators | type == "array" and length > 0) and
    (.renderers | type == "array" and length > 0) and
    .cache_format != null and
    (.limits | type == "object") and
    (.result_schemas | sort) == ([
      "seq-capabilities/v1",
      "seq-command-error/v1",
      "seq-definition-check-result/v1",
      "seq-definition-description/v1",
      "seq-index-result/v1",
      "seq-observation-plan/v1",
      "seq-observation-result/v1"
    ] | sort)
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
