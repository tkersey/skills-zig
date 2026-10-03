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

expect_count 1 "zig build build-seq -Doptimize=fast --summary all"
expect_count 0 "zig build build-seq -Doptimize=debug"
expect_count 0 "working-directory: apps/seq"
expect_count 1 "zig build test-seq test-seq-core test-seq-cli-smoke -Doptimize=fast --summary all"
expect_count 1 "zig build test-definition-core test-definition-core-guard -Doptimize=fast --summary all"
expect_count 1 "zig build test-trace-core -Doptimize=fast --summary all"
expect_count 1 "zig build test-jsonl-core --summary all"
expect_count 1 "zig build test-durable-store --summary all"
expect_count 1 "zig build test-durable-store-perf --summary all"
expect_count 1 "apps/seq/scripts/release/command_surface_gate.sh zig-out/bin/seq"

for token in \
  'Fuzz passive definition parsing (Linux)' \
  'linux_fuzz_gate.sh -- zig build test-definition-core' \
  '-Doptimize=safe --fuzz=100K --summary all'; do
  if ! grep -Fq -- "$token" <<<"$seq_fuzz_job"; then
    echo "Seq fuzz proof token missing: $token" >&2
    exit 1
  fi
done

for token in \
  '"libs/definition_compat/**"' \
  '"tools/perf_contract.zig"' \
  'perf=${selected[seq]:-false}' \
  '${selected[cas]:-false}' \
  "grep -Fxq 'build.zig'" \
  "grep -Fxq 'tools/perf_contract.zig'" \
  "if: needs.changes.outputs.perf == 'true'" \
  "run: zig build test-perf-hub"; do
  if ! grep -Fq -- "$token" "$workflow"; then
    echo "Performance CI ownership token missing: $token" >&2
    exit 1
  fi
done


if grep -Fq -- '${selected[cron]:-false}' "$workflow"; then
  echo "Performance CI still routes through retired Cron release identity" >&2
  exit 1
fi

perf_selector="$(
  awk '
    /^          perf=/ { in_perf = 1 }
    in_perf && /echo "perf=\$perf"/ { exit }
    in_perf { sub(/^          /, ""); print }
  ' "$workflow"
)"
if [[ -z "$perf_selector" ]]; then
  echo "Performance CI selector is missing" >&2
  exit 1
fi

for changed_path in tools/perf_hub.zig tools/perf_contract.zig tools/seq_replay_driver.zig; do
  if ! awk '/^    paths:$/ { in_paths = 1; next } in_paths && !/^      / { exit } in_paths { print }' "$workflow" |
    grep -Fq -- "\"$changed_path\""; then
    echo "Performance source missing from PR workflow admission: $changed_path" >&2
    exit 1
  fi
done

expect_perf_selection() (
  local expected="$1"
  local changed_paths="$2"
  local perf
  declare -A selected=()
  if [[ -n "${3:-}" ]]; then
    selected["$3"]=true
  fi
  eval "$perf_selector"
  if [[ "$perf" != "$expected" ]]; then
    echo "Performance CI selection expected $expected for '$changed_paths' (owner '${3:-none}'); got $perf" >&2
    exit 1
  fi
)

for changed_path in build.zig tools/perf_hub.zig tools/perf_contract.zig tools/seq_replay_driver.zig scripts/perf/example.sh; do
  expect_perf_selection true "$changed_path"
done
expect_perf_selection true apps/seq/src/main.zig seq
expect_perf_selection true apps/cas/src/main.zig cas
expect_perf_selection false README.md

echo "Seq CI proof matrix is valid."
