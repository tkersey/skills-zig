#!/usr/bin/env bash
set -euo pipefail

GH=${GH:-gh}
SLEEP=${SLEEP:-sleep}
not_acquired_marker='was not acquired by Runner'

usage() {
  cat >&2 <<'EOF'
usage: runner_retry.sh resolve <repo> <workflow-file> <since-iso8601> [dispatch-output-file]
       runner_retry.sh supervise <repo> <run-id> <attempts-max> <backoff-seconds>
       runner_retry.sh sweep <repo> <since-iso8601> <attempts-max>
       runner_retry.sh unacquired <repo> <run-id>
EOF
  exit 2
}

only_unacquired_failures() {
  local repo=$1 run=$2 jobs id conclusion steps runner count=0
  jobs=$("$GH" api "repos/$repo/actions/runs/$run/jobs?per_page=100" --jq \
    '.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")
      | "\(.id)\t\(.conclusion)\t\(.steps | length)\t\(.runner_name // "")"')
  [[ -n "$jobs" ]] || return 1
  while IFS=$'\t' read -r id conclusion steps runner; do
    count=$((count + 1))
    [[ "$conclusion" == cancelled && "$steps" == 0 && -z "$runner" ]] || return 1
    "$GH" api "repos/$repo/check-runs/$id/annotations" --jq '.[].message' |
      grep -Fq "$not_acquired_marker" || return 1
  done <<<"$jobs"
  [[ $count -gt 0 ]]
}

resolve_run() {
  local repo=$1 workflow=$2 since=$3 output=${4:-} id="" attempt
  if [[ -n "$output" && -f "$output" ]]; then
    id=$(grep -Eo "/$repo/actions/runs/[0-9]+" "$output" | head -n 1 | grep -Eo '[0-9]+$' || true)
  fi
  for attempt in $(seq 1 24); do
    [[ -n "$id" ]] && break
    id=$("$GH" run list --repo "$repo" --workflow "$workflow" --event workflow_dispatch \
      --limit 20 --json databaseId,createdAt \
      --jq "[.[] | select(.createdAt >= \"$since\")] | sort_by(.createdAt) | .[0].databaseId // empty")
    [[ -n "$id" ]] || "$SLEEP" 5
  done
  [[ -n "$id" ]] || { echo "no $workflow run created since $since" >&2; return 1; }
  printf '%s\n' "$id"
}

supervise_run() {
  local repo=$1 run=$2 attempts_max=$3 backoff=$4 attempt=1 conclusion
  while true; do
    "$GH" run watch "$run" --repo "$repo" --interval 30 >/dev/null 2>&1 || true
    conclusion=$("$GH" run view "$run" --repo "$repo" --json conclusion --jq '.conclusion')
    if [[ "$conclusion" == success ]]; then
      echo "run $run succeeded after $attempt attempt(s)"
      return 0
    fi
    if [[ $attempt -ge $attempts_max ]] || ! only_unacquired_failures "$repo" "$run"; then
      echo "::error::run $run concluded $conclusion after $attempt attempt(s)" >&2
      return 1
    fi
    echo "::notice::run $run: hosted runner never acquired; re-running failed jobs (attempt $((attempt + 1)) of $attempts_max)"
    "$SLEEP" $((backoff * attempt))
    "$GH" run rerun "$run" --repo "$repo" --failed ||
      echo "::warning::rerun request for $run was refused; it may already be re-running"
    attempt=$((attempt + 1))
  done
}

ref_is_current() {
  local repo=$1 ref=$2 sha=$3 current
  [[ -n "$ref" ]] || return 1
  current=$("$GH" api "repos/$repo/commits/$ref" --jq '.sha' 2>/dev/null) || return 1
  [[ "$current" == "$sha" ]]
}

sweep_runs() {
  local repo=$1 since=$2 attempts_max=$3 runs run ref sha rerun_count=0
  runs=$("$GH" api "repos/$repo/actions/runs?status=completed&created=%3E%3D$since&per_page=100" --jq \
    ".workflow_runs[] | select(.conclusion == \"failure\" or .conclusion == \"cancelled\")
      | select(.run_attempt < $attempts_max) | select(.path | endswith(\"retry-unacquired-runners.yml\") | not)
      | \"\\(.id)\\t\\(.head_branch // \"\")\\t\\(.head_sha)\"")
  while IFS=$'\t' read -r run ref sha; do
    [[ -n "$run" ]] || continue
    ref_is_current "$repo" "$ref" "$sha" || continue
    only_unacquired_failures "$repo" "$run" || continue
    if "$GH" run rerun "$run" --repo "$repo" --failed; then
      rerun_count=$((rerun_count + 1))
      echo "re-ran run $run (hosted runner never acquired)"
    else
      echo "::warning::rerun request for $run was refused"
    fi
  done <<<"$runs"
  echo "swept: $rerun_count run(s) re-run"
}

[[ $# -ge 1 ]] || usage
mode=$1
shift
case "$mode" in
  resolve) [[ $# -ge 3 && $# -le 4 ]] || usage; resolve_run "$@" ;;
  supervise) [[ $# -eq 4 ]] || usage; supervise_run "$@" ;;
  sweep) [[ $# -eq 3 ]] || usage; sweep_runs "$@" ;;
  unacquired) [[ $# -eq 2 ]] || usage; only_unacquired_failures "$@" ;;
  *) usage ;;
esac
