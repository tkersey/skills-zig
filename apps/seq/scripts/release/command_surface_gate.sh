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
if ! "$BIN_PATH" --help | rg -q '^- artifact-search$'; then
  echo "required command missing: artifact-search" >&2
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

echo "command-surface gate passed for $BIN_PATH"
