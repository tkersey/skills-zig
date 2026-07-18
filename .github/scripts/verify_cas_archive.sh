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

expected_members=(
  cas
  cas_account
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
if [[ "$target" == "darwin-arm64" ]]; then
  expected_members+=(cas_trial)
fi

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

dispatch_cases=(
  account:cas_account
  conformance:cas_conformance_suite
  goal:cas_goal
  instance_runner:cas_instance_runner
  review_session:cas_review_session
  session_inquiry:cas_session_inquiry
  smoke_check:cas_smoke_check
)
if [[ "$target" == "darwin-arm64" ]]; then
  dispatch_cases+=(trial:cas_trial)
fi

for dispatch_case in "${dispatch_cases[@]}"; do
  subcommand="${dispatch_case%%:*}"
  marker="${dispatch_case#*:}"
  if ! output="$("$payload_dir/cas" "$subcommand" --help 2>&1)"; then
    echo "packaged CAS dispatcher failed to launch $marker for subcommand $subcommand" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq -- "$marker" <<<"$output"; then
    echo "packaged CAS dispatcher output for $subcommand did not identify $marker" >&2
    exit 1
  fi
done

if [[ "$target" == "linux-x86_64" ]] && "$payload_dir/cas" trial --help >/dev/null 2>&1; then
  echo "non-Darwin packaged CAS dispatcher exposes the trial product" >&2
  exit 1
fi

printf 'CAS archive verified: target=%s members=%s packaged_dispatch=pass\n' \
  "$target" "${#expected_members[@]}"
