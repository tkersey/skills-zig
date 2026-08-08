#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <linux-x86_64|darwin-arm64> <archive.tar.gz>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
expected_version="$(tr -d '[:space:]' < "$repo_root/apps/cas/VERSION")"
if [[ -z "$expected_version" ]]; then
  echo "apps/cas/VERSION must contain the CAS release version" >&2
  exit 1
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

expected_members=(
  cas
  cas_account
  cas_app_server_preflight
  cas_automation
  cas_smoke_check
  cas_instance_runner
  cas_review_session
  cas_session_inquiry
  cas_conformance_suite
  cas_goal
  cas-smoke-check
  cas-instance-runner
  cas-review-session
  cas-session-inquiry
  cas-conformance-suite
  cas-goal
  cas-perf-budget-governor
)

expected_normalized="$scratch/expected-normalized"
actual_normalized="$scratch/actual-normalized"
printf '%s\n' "${expected_members[@]}" | LC_ALL=C sort > "$expected_normalized"
awk '
  {
    path = $0
    while (sub(/^\.\//, "", path)) {}
    sub(/\/$/, "", path)
    if (path != "") print path
  }
' "$members" | LC_ALL=C sort > "$actual_normalized"

if ! cmp -s "$expected_normalized" "$actual_normalized"; then
  echo "CAS archive root member set does not match the ${target} release contract" >&2
  diff -u "$expected_normalized" "$actual_normalized" >&2 || true
  exit 1
fi

archive_members=()
for name in "${expected_members[@]}"; do
  member="$(
    awk -v wanted="$name" '
      {
        path = $0
        while (sub(/^\.\//, "", path)) {}
        sub(/\/$/, "", path)
        if (path == wanted) print $0
      }
    ' "$members"
  )"
  if [[ -z "$member" ]]; then
    echo "CAS archive missing required root member: $name" >&2
    exit 1
  fi
  archive_members+=("$member")
done

payload_dir="$scratch/payload"
mkdir -p "$payload_dir"
if ! LC_ALL=C tar -xzf "$archive" -C "$payload_dir" "${archive_members[@]}" >/dev/null; then
  echo "CAS archive required members must be self-contained root entries" >&2
  exit 1
fi

for name in "${expected_members[@]}"; do
  payload="$payload_dir/$name"
  if [[ -L "$payload" || ! -f "$payload" || ! -x "$payload" ]]; then
    echo "CAS archive member must be a regular executable: $name" >&2
    exit 1
  fi
  if [[ -n "$(find "$payload" -type f -links +1 -print -quit)" ]]; then
    echo "CAS archive member must not be a hard link: $name" >&2
    exit 1
  fi
done

for name in "${expected_members[@]}"; do
  payload="$payload_dir/$name"
  if ! version="$("$payload" --version 2>&1)"; then
    echo "CAS archive member failed its version probe: $name" >&2
    printf '%s\n' "$version" >&2
    exit 1
  fi
  if [[ "$version" != "$expected_version" ]]; then
    echo "CAS archive member reported the wrong version: $name expected=$expected_version actual=$version" >&2
    exit 1
  fi
done

dispatch_cases=(
  account:cas_account
  app-server:cas_app_server_preflight
  automation:cas_automation
  conformance:cas_conformance_suite
  goal:cas_goal
  instance_runner:cas_instance_runner
  review:cas_review_session
  session_inquiry:cas_session_inquiry
  smoke_check:cas_smoke_check
)

for dispatch_case in "${dispatch_cases[@]}"; do
  subcommand="${dispatch_case%%:*}"
  marker="${dispatch_case#*:}"
  expected_marker="$marker"
  case "$subcommand" in
    app-server) expected_marker="cas app-server" ;;
    automation) expected_marker="cas automation" ;;
    review) expected_marker="cas review" ;;
  esac
  if ! output="$("$payload_dir/cas" "$subcommand" --help 2>&1)"; then
    echo "packaged CAS dispatcher failed to launch $marker for subcommand $subcommand" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected_marker" <<<"$output"; then
    echo "packaged CAS dispatcher output for $subcommand did not identify $marker" >&2
    exit 1
  fi
done

for removed_subcommand in trial cron ledger review_session; do
  if "$payload_dir/cas" "$removed_subcommand" --help >/dev/null 2>&1; then
    echo "packaged CAS dispatcher exposes removed subcommand: $removed_subcommand" >&2
    exit 1
  fi
done

for help_arg in --help -h help; do
  if ! output="$("$payload_dir/cas_app_server_preflight" "$help_arg" 2>&1)"; then
    echo "packaged cas_app_server_preflight rejected root help form: $help_arg" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq -- "cas app-server" <<<"$output"; then
    echo "packaged cas_app_server_preflight help did not identify its command: $help_arg" >&2
    exit 1
  fi
done

for version_arg in --version version; do
  if ! version="$("$payload_dir/cas_app_server_preflight" "$version_arg" 2>&1)"; then
    echo "packaged cas_app_server_preflight rejected root version form: $version_arg" >&2
    printf '%s\n' "$version" >&2
    exit 1
  fi
  if [[ "$version" != "$expected_version" ]]; then
    echo "packaged cas_app_server_preflight root version mismatch: form=$version_arg expected=$expected_version actual=$version" >&2
    exit 1
  fi
done

printf 'CAS archive verified: target=%s members=%s version=%s packaged_dispatch=pass\n' \
  "$target" "${#expected_members[@]}" "$expected_version"
