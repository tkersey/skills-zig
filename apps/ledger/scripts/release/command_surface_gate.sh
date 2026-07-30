#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
bin_path=${1:-"$root_dir/zig-out/bin/ledger"}

if [[ ! -x "$bin_path" ]]; then
  echo "binary not found or executable: $bin_path" >&2
  exit 1
fi

expected=$'definition check\ndefinition describe\nvalidate\nmaterialize\ntransact\nproject\ndoctor\nrecovery inspect\nrecovery reclaim\ncapabilities\nversion'
help_output=$("$bin_path" --help)
actual=$(
  awk '
    / commands:$/ { in_section = 1; next }
    /^$/ { in_section = 0; next }
    in_section && /^  [^ ]/ {
      line = substr($0, 3)
      sub(/^ledger /, "", line)
      count = split(line, words, /[[:space:]]+/)
      if ((words[1] == "definition" || words[1] == "recovery") && count >= 2) {
        print words[1] " " words[2]
      } else {
        print words[1]
      }
    }
  ' \
    <<<"$help_output"
)

if [[ "$actual" != "$expected" ]]; then
  echo "Ledger 1.0 command surface mismatch" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

capabilities=$("$bin_path" capabilities --format json)
version=$(tr -d '[:space:]' < "$root_dir/apps/ledger/VERSION")
jq -e --arg version "$version" \
  '
    .schema == "ledger-capabilities/v1" and
    .version == $version and
    (.artifact_abis | index("ledger-artifact-abi/v1")) != null and
    (.operators | type == "array" and length > 0) and
    (.codecs | type == "array" and length > 0) and
    (.storage_adapters | type == "array" and length > 0) and
    .cache_format != null and
    (.result_schemas | type == "array" and length > 0)
  ' \
  <<<"$capabilities" >/dev/null

for forbidden in \
  --source \
  actuation \
  universalist \
  learnings \
  negative-ledger \
  synesthesia \
  source-memory-checkpoint
do
  if grep -F -- "$forbidden" <<<"$help_output$capabilities" >/dev/null; then
    echo "Ledger 1.0 exposes domain vocabulary: $forbidden" >&2
    exit 1
  fi
done

echo "Ledger 1.0 command-surface gate passed for $bin_path"
