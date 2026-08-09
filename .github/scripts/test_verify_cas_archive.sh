#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/.github/scripts/verify_cas_archive.sh"
cas_version="$(tr -d '[:space:]' < "$repo_root/apps/cas/VERSION")"
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
  local version="${3:-$cas_version}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'case "${1:-}" in' \
    "  --version|version) printf '%s\\n' '$version' ;;" \
    "  *) printf '%s\\n' '$marker' ;;" \
    'esac' > "$path"
  chmod +x "$path"
}

write_dispatcher() {
  local dir="$1"
  local broken_route="${2:-}"
  # The generated dispatcher expands these values at runtime.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'self_dir="$(cd "$(dirname "$0")" && pwd)"' \
    'subcommand="${1:-}"' \
    'if [[ "$subcommand" == "--version" || "$subcommand" == "version" ]]; then' \
    "  printf '%s\\n' '$cas_version'" \
    '  exit 0' \
    'fi' \
    "if [[ -n '$broken_route' && \"\$subcommand\" == '$broken_route' ]]; then exit 1; fi" \
    'if [[ $# -gt 0 ]]; then shift; fi' \
    'case "$subcommand" in' \
    '  account) sibling=cas_account ;;' \
    '  app-server) sibling=cas_app_server_preflight ;;' \
    '  automation) sibling=cas_automation ;;' \
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
}

write_stub_set() {
  local dir="$1"
  local target="$2"
  mkdir -p "$dir"
  write_dispatcher "$dir"

  for name in \
    cas_account \
    cas_app_server_preflight \
    cas_automation \
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
    if [[ "$name" == "cas_app_server_preflight" ]]; then
      stub_marker="cas app-server"
    fi
    if [[ "$name" == "cas_automation" ]]; then
      stub_marker="cas automation"
    fi
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

clone_set "$tmp/base-linux" "$tmp/missing-app-server"
rm "$tmp/missing-app-server/cas_app_server_preflight"
archive_dot "$tmp/missing-app-server" "$tmp/missing-app-server.tar.gz"

clone_set "$tmp/base-linux" "$tmp/missing-automation"
rm "$tmp/missing-automation/cas_automation"
archive_dot "$tmp/missing-automation" "$tmp/missing-automation.tar.gz"

clone_set "$tmp/base-linux" "$tmp/bundled-ledger"
write_stub "$tmp/bundled-ledger/ledger" ledger
archive_dot "$tmp/bundled-ledger" "$tmp/bundled-ledger.tar.gz"

clone_set "$tmp/base-linux" "$tmp/bundled-cron"
write_stub "$tmp/bundled-cron/cron" cron
archive_dot "$tmp/bundled-cron" "$tmp/bundled-cron.tar.gz"

clone_set "$tmp/base-linux" "$tmp/bundled-cas-trial"
write_stub "$tmp/bundled-cas-trial/cas_trial" cas_trial
archive_dot "$tmp/bundled-cas-trial" "$tmp/bundled-cas-trial.tar.gz"

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
write_dispatcher "$tmp/broken-dispatcher" account
archive_dot "$tmp/broken-dispatcher" "$tmp/broken-dispatcher.tar.gz"

clone_set "$tmp/base-linux" "$tmp/broken-app-server-dispatch"
write_dispatcher "$tmp/broken-app-server-dispatch" app-server
archive_dot "$tmp/broken-app-server-dispatch" "$tmp/broken-app-server-dispatch.tar.gz"

clone_set "$tmp/base-linux" "$tmp/broken-automation-dispatch"
write_dispatcher "$tmp/broken-automation-dispatch" automation
archive_dot "$tmp/broken-automation-dispatch" "$tmp/broken-automation-dispatch.tar.gz"

clone_set "$tmp/base-linux" "$tmp/wrong-version"
write_stub "$tmp/wrong-version/cas_goal" cas_goal "${cas_version}-wrong"
archive_dot "$tmp/wrong-version" "$tmp/wrong-version.tar.gz"

"$verifier" darwin-arm64 "$tmp/darwin-dot.tar.gz" >/dev/null
"$verifier" darwin-arm64 "$tmp/darwin-bare.tar.gz" >/dev/null
"$verifier" linux-x86_64 "$tmp/linux.tar.gz" >/dev/null
expect_fail linux-x86_64 "$tmp/missing-sibling.tar.gz" "missing dispatcher sibling"
expect_fail linux-x86_64 "$tmp/missing-app-server.tar.gz" "missing app-server preflight sibling"
expect_fail linux-x86_64 "$tmp/missing-automation.tar.gz" "missing automation sibling"
expect_fail linux-x86_64 "$tmp/bundled-ledger.tar.gz" "bundled Ledger executable"
expect_fail linux-x86_64 "$tmp/bundled-cron.tar.gz" "bundled Cron executable"
expect_fail linux-x86_64 "$tmp/bundled-cas-trial.tar.gz" "bundled cas_trial executable"
expect_fail linux-x86_64 "$tmp/non-executable-sibling.tar.gz" "non-executable dispatcher sibling"
expect_fail linux-x86_64 "$tmp/symlink-sibling.tar.gz" "symbolic-link dispatcher sibling"
expect_fail linux-x86_64 "$tmp/hardlink-sibling.tar.gz" "hard-link dispatcher sibling"
expect_fail linux-x86_64 "$tmp/missing-alias.tar.gz" "missing compatibility alias"
expect_fail linux-x86_64 "$tmp/broken-dispatcher.tar.gz" "broken packaged dispatcher"
expect_fail linux-x86_64 "$tmp/broken-app-server-dispatch.tar.gz" "broken app-server dispatch"
expect_fail linux-x86_64 "$tmp/broken-automation-dispatch.tar.gz" "broken automation dispatch"
expect_fail linux-x86_64 "$tmp/wrong-version.tar.gz" "wrong executable version"

echo "CAS archive verifier: 17/17 cases passed"
