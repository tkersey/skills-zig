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

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
members="$scratch/members"
LC_ALL=C tar -tzf "$archive" > "$members"

root_count="$(
  awk '$0 == "cas_trial" || $0 == "./cas_trial" { count += 1 } END { print count + 0 }' "$members"
)"
cas_trial_count="$(
  awk '{
    path = $0
    sub(/\/$/, "", path)
    count = split(path, parts, "/")
    if (parts[count] == "cas_trial") matches += 1
  } END { print matches + 0 }' "$members"
)"

if [[ "$target" == "darwin-arm64" ]]; then
  if [[ "$root_count" -ne 1 || "$cas_trial_count" -ne 1 ]]; then
    echo "Darwin CAS archive must contain exactly one root cas_trial and no nested copies; observed root=$root_count total=$cas_trial_count" >&2
    exit 1
  fi

  root_member="$(awk '$0 == "cas_trial" || $0 == "./cas_trial" { print; exit }' "$members")"
  payload_dir="$scratch/payload"
  mkdir -p "$payload_dir"
  if ! LC_ALL=C tar -xzf "$archive" -C "$payload_dir" "$root_member" >/dev/null; then
    echo "Darwin CAS archive cas_trial must be a self-contained root entry" >&2
    exit 1
  fi

  payload="$payload_dir/cas_trial"
  if [[ -L "$payload" || ! -f "$payload" || ! -x "$payload" ]]; then
    echo "Darwin CAS archive cas_trial must be a regular executable" >&2
    exit 1
  fi
  if [[ -n "$(find "$payload" -type f -links +1 -print -quit)" ]]; then
    echo "Darwin CAS archive cas_trial must not be a hard link" >&2
    exit 1
  fi
elif [[ "$cas_trial_count" -ne 0 ]]; then
  echo "Non-Darwin CAS archive must not contain cas_trial; observed $cas_trial_count" >&2
  exit 1
fi

printf 'CAS archive verified: target=%s cas_trial=%s\n' "$target" "$cas_trial_count"
