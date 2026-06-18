#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_LIB="$ROOT_DIR/src/lib.zig"
BIN_PATH="${1:-$ROOT_DIR/zig-out/bin/seq}"

if [[ ! -f "$SRC_LIB" ]]; then
  echo "source file not found: $SRC_LIB" >&2
  exit 1
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "binary not found/executable: $BIN_PATH" >&2
  echo "build first: (cd $ROOT_DIR && zig build -Doptimize=ReleaseSafe)" >&2
  exit 1
fi

expected="$(rg -N '\.name = "' "$SRC_LIB" | sed -E 's/.*\.name = "([^"]+)".*/\1/' | sort)"
actual="$("$BIN_PATH" --help | sed -n 's/^- //p' | sort)"

if [[ "$expected" != "$actual" ]]; then
  echo "command-surface mismatch between source and built binary" >&2
  echo "--- expected (src/lib.zig) ---" >&2
  printf '%s\n' "$expected" >&2
  echo "--- actual ($BIN_PATH --help) ---" >&2
  printf '%s\n' "$actual" >&2
  exit 1
fi

if ! "$BIN_PATH" --help | rg -q '^- session-tooling$'; then
  echo "required command missing: session-tooling" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- query-diagnose$'; then
  echo "required command missing: query-diagnose" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- goal-audit$'; then
  echo "required command missing: goal-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- artifact-search$'; then
  echo "required command missing: artifact-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- workflow-overlap$'; then
  echo "required command missing: workflow-overlap" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- skill-audit$'; then
  echo "required command missing: skill-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- tool-audit$'; then
  echo "required command missing: tool-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-inventory$'; then
  echo "required command missing: memory-inventory" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- message-search$'; then
  echo "required command missing: message-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- workdir-report$'; then
  echo "required command missing: workdir-report" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-provenance$'; then
  echo "required command missing: memory-provenance" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-map$'; then
  echo "required command missing: memory-map" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-history$'; then
  echo "required command missing: memory-history" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- plan-search$'; then
  echo "required command missing: plan-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- reply-latency$'; then
  echo "required command missing: reply-latency" >&2
  exit 1
fi
if ! "$BIN_PATH" token-usage --help | rg -q -- '--last <duration>'; then
  echo "token-usage help missing --last duration support" >&2
  exit 1
fi
if ! "$BIN_PATH" token-cost --help | rg -q -- '--pricing <kind>'; then
  echo "token-cost help missing pricing mode support" >&2
  exit 1
fi
if ! "$BIN_PATH" token-cost --help | rg -q -- '--model <name>'; then
  echo "token-cost help missing API model override support" >&2
  exit 1
fi
if ! "$BIN_PATH" artifact-search --help | rg -q -- '--contains-any <csv>'; then
  echo "artifact-search help missing --contains-any support" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | rg -q -- 'term-summary'; then
  echo "workflow-audit help missing term-summary mode" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | rg -q -- 'cohort-report'; then
  echo "workflow-audit help missing cohort-report mode" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | rg -q -- '--term-group <name=csv>'; then
  echo "workflow-audit help missing --term-group support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-blocks --help | rg -q -- '--mode blocks|term-counts|term-summary'; then
  echo "skill-blocks help missing native term-analysis modes" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-blocks --help | rg -q -- '--term-group <name=csv>'; then
  echo "skill-blocks help missing --term-group support" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-overlap --help | rg -q -- '--mode summary|sessions'; then
  echo "workflow-overlap help missing summary/sessions modes" >&2
  exit 1
fi
if ! "$BIN_PATH" adjudication-audit --help | rg -q -- '--mode summary|rows|report'; then
  echo "adjudication-audit help missing native summary/rows/report modes" >&2
  exit 1
fi
for cmd in skill-audit tool-audit memory-inventory message-search workdir-report; do
  if ! "$BIN_PATH" --help | rg -q "^- ${cmd}$"; then
    echo "required command missing: ${cmd}" >&2
    exit 1
  fi
done

echo "command-surface gate passed for $BIN_PATH"
