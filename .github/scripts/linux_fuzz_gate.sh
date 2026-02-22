#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 [--timeout-seconds N] -- <command...>" >&2
  exit 2
fi

timeout_seconds="${FUZZ_TIMEOUT_SECONDS:-180}"
if [[ "${1:-}" == "--timeout-seconds" ]]; then
  if [[ $# -lt 3 ]]; then
    echo "missing timeout value" >&2
    exit 2
  fi
  timeout_seconds="$2"
  shift 2
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "missing fuzz command" >&2
  exit 2
fi

timeout_bin="timeout"
if ! command -v "$timeout_bin" >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  else
    echo "no timeout binary found; running command without timeout guard" >&2
    set +e
    "$@"
    exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
      exit "$exit_code"
    fi
    exit 0
  fi
fi

set +e
"$timeout_bin" "$timeout_seconds" "$@"
exit_code=$?
set -e

if [[ "$exit_code" -ne 0 && "$exit_code" -ne 124 ]]; then
  exit "$exit_code"
fi
