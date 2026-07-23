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
    '  review) sibling=cas_review_session ;;' \
    '  session_inquiry) sibling=cas_session_inquiry ;;' \
    '  smoke_check) sibling=cas_smoke_check ;;' \
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
    stub_marker="$name"
    if [[ "$name" == "cas_review_session" ]]; then
      stub_marker="cas review"
    fi
    write_stub "$dir/$name" "$stub_marker"
  done
  : "$target"
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
expect_fail linux-x86_64 "$tmp/missing-sibling.tar.gz" "missing dispatcher sibling"
expect_fail linux-x86_64 "$tmp/non-executable-sibling.tar.gz" "non-executable dispatcher sibling"
expect_fail linux-x86_64 "$tmp/symlink-sibling.tar.gz" "symbolic-link dispatcher sibling"
expect_fail linux-x86_64 "$tmp/hardlink-sibling.tar.gz" "hard-link dispatcher sibling"
expect_fail linux-x86_64 "$tmp/missing-alias.tar.gz" "missing compatibility alias"
expect_fail linux-x86_64 "$tmp/broken-dispatcher.tar.gz" "broken packaged dispatcher"

echo "CAS archive verifier: 9/9 cases passed"
