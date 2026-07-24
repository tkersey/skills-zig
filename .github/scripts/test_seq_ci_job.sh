#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="${1:-$repo_root/.github/workflows/pr-ci.yml}"

if [[ ! -r "$workflow" ]]; then
  echo "Seq CI workflow is not readable: $workflow" >&2
  exit 1
fi

seq_job="$(
  awk '
    /^  seq:$/ {
      in_seq = 1
    }
    in_seq && /^  [[:alnum:]_-]+:$/ && $0 != "  seq:" {
      exit
    }
    in_seq {
      print
    }
  ' "$workflow"
)"

if [[ -z "$seq_job" ]]; then
  echo "Seq CI job is missing from $workflow" >&2
  exit 1
fi

seq_fuzz_job="$(
  awk '
    /^  seq-fuzz-linux:$/ {
      in_seq_fuzz = 1
    }
    in_seq_fuzz && /^  [[:alnum:]_-]+:$/ && $0 != "  seq-fuzz-linux:" {
      exit
    }
    in_seq_fuzz {
      print
    }
  ' "$workflow"
)"

if [[ -z "$seq_fuzz_job" ]]; then
  echo "Seq fuzz CI job is missing from $workflow" >&2
  exit 1
fi

expect_count() {
  local expected="$1"
  local needle="$2"
  local observed

  observed="$(
    awk -v needle="$needle" '
      {
        line = $0
        while ((offset = index(line, needle)) != 0) {
          count += 1
          line = substr(line, offset + length(needle))
        }
      }
      END {
        print count + 0
      }
    ' <<<"$seq_job"
  )"

  if [[ "$observed" != "$expected" ]]; then
    echo "Seq CI proof matrix expected $expected occurrence(s) of '$needle'; found $observed" >&2
    exit 1
  fi
}

expect_count 1 "zig build build-seq -Doptimize=Debug --summary all"
expect_count 0 "ReleaseFast"
expect_count 0 "working-directory: apps/seq"
expect_count 1 "zig build test-seq --summary all"
expect_count 1 "zig build test-retrace-core --summary all"
expect_count 1 "apps/seq/scripts/release/command_surface_gate.sh zig-out/bin/seq"

for token in \
  '--dep jsonl_core -Mretrace_core=../../libs/retrace_core/src/lib.zig' \
  '-Mjsonl_core=../../libs/jsonl_core/src/lib.zig'; do
  if ! grep -Fq -- "$token" <<<"$seq_fuzz_job"; then
    echo "Seq fuzz dependency token missing: $token" >&2
    exit 1
  fi
done

echo "Seq CI proof matrix is valid."
