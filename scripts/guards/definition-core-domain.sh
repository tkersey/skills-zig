#!/usr/bin/env bash
set -euo pipefail

readonly pattern='(^|[^[:alnum:]_])(skill|seq|ledger|actuating|universalist|review-compiler|resolve|learnings|negative-ledger|synesthesia|cas|SKDC|SDR|EPG)([^[:alnum:]_]|$)'

if rg -n -i "$pattern" libs/definition_core; then
  echo "definition_core contains domain vocabulary" >&2
  exit 1
fi
