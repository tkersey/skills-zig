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

expect_count 1 "zig build build-seq -Doptimize=ReleaseFast --summary all"
expect_count 0 "zig build build-seq -Doptimize=Debug"
expect_count 0 "working-directory: apps/seq"
expect_count 1 "zig build test-seq test-seq-core test-seq-cli-smoke -Doptimize=ReleaseFast --summary all"
expect_count 1 "zig build test-definition-core test-definition-core-guard -Doptimize=ReleaseFast --summary all"
expect_count 1 "zig build test-trace-core -Doptimize=ReleaseFast --summary all"
expect_count 1 "zig build test-jsonl-core --summary all"
expect_count 1 "zig build test-durable-store --summary all"
expect_count 1 "zig build test-durable-store-perf --summary all"
expect_count 1 "apps/seq/scripts/release/command_surface_gate.sh zig-out/bin/seq"

for token in \
  'Fuzz passive definition parsing (Linux)' \
  'zig test -Mroot=libs/definition_core/src/root.zig -ffuzz --test-filter "fuzz "'; do
  if ! grep -Fq -- "$token" <<<"$seq_fuzz_job"; then
    echo "Seq fuzz proof token missing: $token" >&2
    exit 1
  fi
done

for token in \
  '"libs/definition_compat/**"' \
  '"tools/perf_contract.zig"' \
  'perf=${selected[seq]:-false}' \
  '${selected[cron]:-false}' \
  "grep -Fxq 'build.zig'" \
  "grep -Fxq 'tools/perf_contract.zig'" \
  "if: needs.changes.outputs.perf == 'true'" \
  "run: zig build test-perf-hub"; do
  if ! grep -Fq -- "$token" "$workflow"; then
    echo "Performance CI ownership token missing: $token" >&2
    exit 1
  fi
done

echo "Seq CI proof matrix is valid."
