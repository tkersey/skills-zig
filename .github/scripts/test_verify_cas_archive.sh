#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/.github/scripts/verify_cas_archive.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_fail() {
  local target="$1"
  local archive="$2"
  local label="$3"
  if "$verifier" "$target" "$archive" >/dev/null 2>&1; then
    echo "expected $label to fail" >&2
    exit 1
  fi
}

mkdir -p \
  "$tmp/darwin-dot" \
  "$tmp/darwin-bare" \
  "$tmp/linux" \
  "$tmp/linux-root-contaminated" \
  "$tmp/linux-nested-contaminated/subdir" \
  "$tmp/darwin-missing" \
  "$tmp/darwin-nested/subdir" \
  "$tmp/darwin-root-and-nested/subdir" \
  "$tmp/darwin-non-executable" \
  "$tmp/darwin-symlink" \
  "$tmp/darwin-hardlink" \
  "$tmp/darwin-duplicate"

for dir in \
  darwin-dot \
  darwin-bare \
  linux \
  linux-root-contaminated \
  linux-nested-contaminated \
  darwin-missing \
  darwin-nested \
  darwin-root-and-nested \
  darwin-non-executable \
  darwin-symlink \
  darwin-hardlink; do
  printf 'cas\n' > "$tmp/$dir/cas"
  chmod +x "$tmp/$dir/cas"
done

printf 'cas_trial\n' > "$tmp/darwin-dot/cas_trial"
printf 'cas_trial\n' > "$tmp/darwin-bare/cas_trial"
printf 'cas_trial\n' > "$tmp/linux-root-contaminated/cas_trial"
printf 'cas_trial\n' > "$tmp/linux-nested-contaminated/subdir/cas_trial"
printf 'cas_trial\n' > "$tmp/darwin-nested/subdir/cas_trial"
printf 'cas_trial\n' > "$tmp/darwin-root-and-nested/cas_trial"
printf 'cas_trial\n' > "$tmp/darwin-root-and-nested/subdir/cas_trial"
printf 'cas_trial\n' > "$tmp/darwin-non-executable/cas_trial"
printf 'cas_trial\n' > "$tmp/darwin-duplicate/cas_trial"
chmod +x \
  "$tmp/darwin-dot/cas_trial" \
  "$tmp/darwin-bare/cas_trial" \
  "$tmp/linux-root-contaminated/cas_trial" \
  "$tmp/linux-nested-contaminated/subdir/cas_trial" \
  "$tmp/darwin-nested/subdir/cas_trial" \
  "$tmp/darwin-root-and-nested/cas_trial" \
  "$tmp/darwin-root-and-nested/subdir/cas_trial" \
  "$tmp/darwin-duplicate/cas_trial"
ln -s cas "$tmp/darwin-symlink/cas_trial"
ln "$tmp/darwin-hardlink/cas" "$tmp/darwin-hardlink/cas_trial"

tar -czf "$tmp/darwin-dot.tar.gz" -C "$tmp/darwin-dot" .
tar -czf "$tmp/darwin-bare.tar.gz" -C "$tmp/darwin-bare" cas cas_trial
tar -czf "$tmp/linux.tar.gz" -C "$tmp/linux" .
tar -czf "$tmp/linux-root-contaminated.tar.gz" -C "$tmp/linux-root-contaminated" .
tar -czf "$tmp/linux-nested-contaminated.tar.gz" -C "$tmp/linux-nested-contaminated" .
tar -czf "$tmp/darwin-missing.tar.gz" -C "$tmp/darwin-missing" .
tar -czf "$tmp/darwin-nested.tar.gz" -C "$tmp/darwin-nested" .
tar -czf "$tmp/darwin-root-and-nested.tar.gz" -C "$tmp/darwin-root-and-nested" .
tar -czf "$tmp/darwin-non-executable.tar.gz" -C "$tmp/darwin-non-executable" .
tar -czf "$tmp/darwin-symlink.tar.gz" -C "$tmp/darwin-symlink" .
tar -czf "$tmp/darwin-hardlink.tar.gz" -C "$tmp/darwin-hardlink" cas cas_trial
tar -czf "$tmp/darwin-duplicate.tar.gz" -C "$tmp/darwin-duplicate" cas_trial cas_trial

"$verifier" darwin-arm64 "$tmp/darwin-dot.tar.gz" >/dev/null
"$verifier" darwin-arm64 "$tmp/darwin-bare.tar.gz" >/dev/null
"$verifier" linux-x86_64 "$tmp/linux.tar.gz" >/dev/null
expect_fail linux-x86_64 "$tmp/linux-root-contaminated.tar.gz" "non-Darwin root contamination"
expect_fail linux-x86_64 "$tmp/linux-nested-contaminated.tar.gz" "non-Darwin nested contamination"
expect_fail darwin-arm64 "$tmp/darwin-missing.tar.gz" "Darwin missing cas_trial"
expect_fail darwin-arm64 "$tmp/darwin-nested.tar.gz" "Darwin nested-only cas_trial"
expect_fail darwin-arm64 "$tmp/darwin-root-and-nested.tar.gz" "Darwin root plus nested cas_trial"
expect_fail darwin-arm64 "$tmp/darwin-non-executable.tar.gz" "Darwin non-executable cas_trial"
expect_fail darwin-arm64 "$tmp/darwin-symlink.tar.gz" "Darwin symbolic-link cas_trial"
expect_fail darwin-arm64 "$tmp/darwin-hardlink.tar.gz" "Darwin hard-link cas_trial"
expect_fail darwin-arm64 "$tmp/darwin-duplicate.tar.gz" "Darwin duplicate root cas_trial"

echo "CAS archive verifier: 12/12 cases passed"
