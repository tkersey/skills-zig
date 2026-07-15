#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/.github/scripts/verify_cas_archive.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/darwin" "$tmp/linux" "$tmp/linux-contaminated" "$tmp/darwin-missing"
printf 'cas\n' > "$tmp/darwin/cas"
printf 'cas_trial\n' > "$tmp/darwin/cas_trial"
printf 'cas\n' > "$tmp/linux/cas"
printf 'cas\n' > "$tmp/linux-contaminated/cas"
printf 'cas_trial\n' > "$tmp/linux-contaminated/cas_trial"
printf 'cas\n' > "$tmp/darwin-missing/cas"

tar -czf "$tmp/darwin.tar.gz" -C "$tmp/darwin" .
tar -czf "$tmp/linux.tar.gz" -C "$tmp/linux" .
tar -czf "$tmp/linux-contaminated.tar.gz" -C "$tmp/linux-contaminated" .
tar -czf "$tmp/darwin-missing.tar.gz" -C "$tmp/darwin-missing" .

"$verifier" darwin-arm64 "$tmp/darwin.tar.gz" >/dev/null
"$verifier" linux-x86_64 "$tmp/linux.tar.gz" >/dev/null

if "$verifier" linux-x86_64 "$tmp/linux-contaminated.tar.gz" >/dev/null 2>&1; then
  echo "expected non-Darwin archive containing cas_trial to fail" >&2
  exit 1
fi

if "$verifier" darwin-arm64 "$tmp/darwin-missing.tar.gz" >/dev/null 2>&1; then
  echo "expected Darwin archive missing cas_trial to fail" >&2
  exit 1
fi

echo "CAS archive verifier: 4/4 cases passed"
