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

write_stub() {
  local path="$1"
  local marker="$2"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "printf '%s\\n' '$marker'" > "$path"
  chmod +x "$path"
}

write_stub_set() {
  local dir="$1"
  local target="$2"
  mkdir -p "$dir"
  # The generated dispatcher expands these values at runtime.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'self_dir="$(cd "$(dirname "$0")" && pwd)"' \
    'subcommand="${1:-}"' \
    'if [[ $# -gt 0 ]]; then shift; fi' \
    'case "$subcommand" in' \
    '  account) sibling=cas_account ;;' \
    '  conformance) sibling=cas_conformance_suite ;;' \
    '  goal) sibling=cas_goal ;;' \
    '  instance_runner) sibling=cas_instance_runner ;;' \
    '  review_session) sibling=cas_review_session ;;' \
    '  session_inquiry) sibling=cas_session_inquiry ;;' \
    '  smoke_check) sibling=cas_smoke_check ;;' \
    '  trial) sibling=cas_trial ;;' \
    '  *) exit 2 ;;' \
    'esac' \
    'exec "$self_dir/$sibling" "$@"' > "$dir/cas"
  chmod +x "$dir/cas"

  for name in \
    cas_account \
    cas_smoke_check \
    cas_instance_runner \
    cas_review_session \
    cas_session_inquiry \
    cas_conformance_suite \
    cas_goal \
    cas-smoke-check \
    cas-instance-runner \
    cas-review-session \
    cas-session-inquiry \
    cas-conformance-suite \
    cas-goal \
    cas-perf-budget-governor; do
    write_stub "$dir/$name" "$name"
  done
  if [[ "$target" == "darwin-arm64" ]]; then
    write_stub "$dir/cas_trial" cas_trial
  fi
}

clone_set() {
  local source="$1"
  local destination="$2"
  cp -R "$source" "$destination"
}

archive_dot() {
  local source="$1"
  local archive="$2"
  tar -czf "$archive" -C "$source" .
}

write_stub_set "$tmp/base-linux" linux-x86_64
write_stub_set "$tmp/base-darwin" darwin-arm64

archive_dot "$tmp/base-darwin" "$tmp/darwin-dot.tar.gz"
(
  cd "$tmp/base-darwin"
  tar -czf "$tmp/darwin-bare.tar.gz" ./*
)
archive_dot "$tmp/base-linux" "$tmp/linux.tar.gz"

clone_set "$tmp/base-linux" "$tmp/linux-root-contaminated"
write_stub "$tmp/linux-root-contaminated/cas_trial" cas_trial
archive_dot "$tmp/linux-root-contaminated" "$tmp/linux-root-contaminated.tar.gz"

clone_set "$tmp/base-linux" "$tmp/linux-nested-contaminated"
mkdir -p "$tmp/linux-nested-contaminated/subdir"
write_stub "$tmp/linux-nested-contaminated/subdir/cas_trial" cas_trial
archive_dot "$tmp/linux-nested-contaminated" "$tmp/linux-nested-contaminated.tar.gz"

clone_set "$tmp/base-darwin" "$tmp/darwin-missing"
rm "$tmp/darwin-missing/cas_trial"
archive_dot "$tmp/darwin-missing" "$tmp/darwin-missing.tar.gz"

clone_set "$tmp/base-darwin" "$tmp/darwin-nested"
rm "$tmp/darwin-nested/cas_trial"
mkdir -p "$tmp/darwin-nested/subdir"
write_stub "$tmp/darwin-nested/subdir/cas_trial" cas_trial
archive_dot "$tmp/darwin-nested" "$tmp/darwin-nested.tar.gz"

clone_set "$tmp/base-darwin" "$tmp/darwin-root-and-nested"
mkdir -p "$tmp/darwin-root-and-nested/subdir"
write_stub "$tmp/darwin-root-and-nested/subdir/cas_trial" cas_trial
archive_dot "$tmp/darwin-root-and-nested" "$tmp/darwin-root-and-nested.tar.gz"

clone_set "$tmp/base-darwin" "$tmp/darwin-non-executable"
chmod -x "$tmp/darwin-non-executable/cas_trial"
archive_dot "$tmp/darwin-non-executable" "$tmp/darwin-non-executable.tar.gz"

clone_set "$tmp/base-darwin" "$tmp/darwin-symlink"
rm "$tmp/darwin-symlink/cas_trial"
ln -s cas "$tmp/darwin-symlink/cas_trial"
archive_dot "$tmp/darwin-symlink" "$tmp/darwin-symlink.tar.gz"

clone_set "$tmp/base-darwin" "$tmp/darwin-hardlink"
rm "$tmp/darwin-hardlink/cas_trial"
ln "$tmp/darwin-hardlink/cas" "$tmp/darwin-hardlink/cas_trial"
archive_dot "$tmp/darwin-hardlink" "$tmp/darwin-hardlink.tar.gz"

tar -czf "$tmp/darwin-duplicate.tar.gz" -C "$tmp/base-darwin" . cas_trial

clone_set "$tmp/base-linux" "$tmp/missing-sibling"
rm "$tmp/missing-sibling/cas_review_session"
archive_dot "$tmp/missing-sibling" "$tmp/missing-sibling.tar.gz"

clone_set "$tmp/base-linux" "$tmp/non-executable-sibling"
chmod -x "$tmp/non-executable-sibling/cas_review_session"
archive_dot "$tmp/non-executable-sibling" "$tmp/non-executable-sibling.tar.gz"

clone_set "$tmp/base-linux" "$tmp/symlink-sibling"
rm "$tmp/symlink-sibling/cas_review_session"
ln -s cas "$tmp/symlink-sibling/cas_review_session"
archive_dot "$tmp/symlink-sibling" "$tmp/symlink-sibling.tar.gz"

clone_set "$tmp/base-linux" "$tmp/hardlink-sibling"
rm "$tmp/hardlink-sibling/cas_review_session"
ln "$tmp/hardlink-sibling/cas" "$tmp/hardlink-sibling/cas_review_session"
archive_dot "$tmp/hardlink-sibling" "$tmp/hardlink-sibling.tar.gz"

clone_set "$tmp/base-linux" "$tmp/missing-alias"
rm "$tmp/missing-alias/cas-review-session"
archive_dot "$tmp/missing-alias" "$tmp/missing-alias.tar.gz"

clone_set "$tmp/base-linux" "$tmp/broken-dispatcher"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$tmp/broken-dispatcher/cas"
chmod +x "$tmp/broken-dispatcher/cas"
archive_dot "$tmp/broken-dispatcher" "$tmp/broken-dispatcher.tar.gz"

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
expect_fail linux-x86_64 "$tmp/missing-sibling.tar.gz" "missing dispatcher sibling"
expect_fail linux-x86_64 "$tmp/non-executable-sibling.tar.gz" "non-executable dispatcher sibling"
expect_fail linux-x86_64 "$tmp/symlink-sibling.tar.gz" "symbolic-link dispatcher sibling"
expect_fail linux-x86_64 "$tmp/hardlink-sibling.tar.gz" "hard-link dispatcher sibling"
expect_fail linux-x86_64 "$tmp/missing-alias.tar.gz" "missing compatibility alias"
expect_fail linux-x86_64 "$tmp/broken-dispatcher.tar.gz" "broken packaged dispatcher"

echo "CAS archive verifier: 18/18 cases passed"
