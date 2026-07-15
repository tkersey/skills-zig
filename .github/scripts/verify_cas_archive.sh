#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <linux-x86_64|darwin-arm64> <archive.tar.gz>" >&2
  exit 2
fi

target="$1"
archive="$2"

case "$target" in
  linux-x86_64|darwin-arm64) ;;
  *)
    echo "unsupported CAS release target: $target" >&2
    exit 2
    ;;
esac

if [[ ! -f "$archive" ]]; then
  echo "CAS release archive does not exist: $archive" >&2
  exit 1
fi

cas_trial_count="$(
  tar -tzf "$archive" |
    sed 's#^\./##' |
    awk '$0 == "cas_trial" || $0 ~ /\/cas_trial$/ { count += 1 } END { print count + 0 }'
)"

if [[ "$target" == "darwin-arm64" ]]; then
  if [[ "$cas_trial_count" -ne 1 ]]; then
    echo "Darwin CAS archive must contain exactly one cas_trial; observed $cas_trial_count" >&2
    exit 1
  fi
elif [[ "$cas_trial_count" -ne 0 ]]; then
  echo "Non-Darwin CAS archive must not contain cas_trial; observed $cas_trial_count" >&2
  exit 1
fi

printf 'CAS archive verified: target=%s cas_trial=%s\n' "$target" "$cas_trial_count"
