#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
script="$repo_root/.github/scripts/runner_retry.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/runner-retry.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

cat >"$work/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=$FAKE_DIR
attempt_of() { cat "$state/attempt-$1" 2>/dev/null || echo 1; }
filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == --jq ]] && filter="${args[$((i + 1))]}"
done
case "$1 $2" in
  "api "*)
    path=$2
    if [[ "$path" =~ actions/runs/([0-9]+)/jobs ]]; then
      run=${BASH_REMATCH[1]}
      jq -r "$filter" "$state/jobs-$run-$(attempt_of "$run").json"
    elif [[ "$path" =~ check-runs/([0-9]+)/annotations ]]; then
      file="$state/annotations-${BASH_REMATCH[1]}.json"
      [[ -f "$file" ]] || file=/dev/null
      if [[ "$file" == /dev/null ]]; then echo '[]' | jq -r "$filter"; else jq -r "$filter" "$file"; fi
    elif [[ "$path" == *"actions/runs?"* ]]; then
      jq -r "$filter" "$state/runs.json"
    elif [[ "$path" =~ /commits/(.+)$ ]]; then
      file="$state/commit-${BASH_REMATCH[1]//\//_}"
      [[ -f "$file" ]] || { echo "Not Found" >&2; exit 1; }
      cat "$file"
    else
      echo "unexpected api path $path" >&2; exit 1
    fi
    ;;
  "run watch") ;;
  "run view")
    cat "$state/conclusion-$3-$(attempt_of "$3")"
    ;;
  "run rerun")
    run=$3
    echo "$run" >>"$state/reruns"
    [[ -f "$state/refuse-$run" ]] && exit 1
    echo $(($(attempt_of "$run") + 1)) >"$state/attempt-$run"
    ;;
  "run list")
    jq -r "$filter" "$state/list.json"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/gh"
cat >"$work/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DIR/sleeps"
EOF
chmod +x "$work/sleep"
export GH="$work/gh" SLEEP="$work/sleep"

reset_state() {
  export FAKE_DIR="$work/state-$1"
  mkdir -p "$FAKE_DIR"
}

unacquired_job() {
  printf '{"jobs":[{"id":%s,"conclusion":"cancelled","steps":[],"runner_name":""},' "$1"
  printf '{"id":9,"conclusion":"success","steps":[{}],"runner_name":"GitHub Actions 1"}]}\n'
}

not_acquired_annotation() {
  printf '[{"message":"The job was not acquired by Runner of type hosted even after multiple attempts"}]\n' \
    >"$FAKE_DIR/annotations-$1.json"
}

expect() {
  local label=$1
  shift
  if "$@"; then echo "ok: $label"; else echo "FAIL: $label" >&2; exit 1; fi
}

expect_not() {
  local label=$1
  shift
  if "$@"; then echo "FAIL: $label" >&2; exit 1; else echo "ok: $label"; fi
}

reset_state classify
unacquired_job 11 >"$FAKE_DIR/jobs-100-1.json"
not_acquired_annotation 11
expect "never-acquired cancellation is retryable" "$script" unacquired o/r 100
printf '{"jobs":[{"id":12,"conclusion":"failure","steps":[{}],"runner_name":"GitHub Actions 2"}]}\n' \
  >"$FAKE_DIR/jobs-101-1.json"
expect_not "a real job failure is not retryable" "$script" unacquired o/r 101
printf '{"jobs":[{"id":13,"conclusion":"cancelled","steps":[{}],"runner_name":"GitHub Actions 3"}]}\n' \
  >"$FAKE_DIR/jobs-102-1.json"
expect_not "a cancellation after steps ran is not retryable" "$script" unacquired o/r 102
unacquired_job 14 >"$FAKE_DIR/jobs-103-1.json"
expect_not "a cancellation without the runner annotation is not retryable" "$script" unacquired o/r 103
printf '{"jobs":[{"id":15,"conclusion":"success","steps":[{}],"runner_name":"x"}]}\n' \
  >"$FAKE_DIR/jobs-104-1.json"
expect_not "a run with no failed jobs is not retryable" "$script" unacquired o/r 104
printf '{"jobs":[]}\n' >"$FAKE_DIR/jobs-105-1.json"
unacquired_job 16 | jq -c '.jobs += [{"id":17,"conclusion":"failure","steps":[{}],"runner_name":"y"}]' \
  >"$FAKE_DIR/jobs-106-1.json"
not_acquired_annotation 16
expect_not "a mix of unacquired and real failures is not retryable" "$script" unacquired o/r 106

unacquired_job 18 >"$FAKE_DIR/jobs-107-1.json"
jq -n '[{"message":"The job was not acquired by Runner of type hosted even after multiple attempts"}]
  + [range(20000) | {"message":"Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times."}]' \
  >"$FAKE_DIR/annotations-18.json"
expect "a match followed by long annotation output is still retryable" "$script" unacquired o/r 107

reset_state supervise-success
echo success >"$FAKE_DIR/conclusion-200-1"
expect "a successful run needs no retry" "$script" supervise o/r 200 4 60
[[ ! -f "$FAKE_DIR/reruns" ]] || { echo "FAIL: unexpected rerun" >&2; exit 1; }

reset_state supervise-retry
echo failure >"$FAKE_DIR/conclusion-201-1"
echo failure >"$FAKE_DIR/conclusion-201-2"
echo success >"$FAKE_DIR/conclusion-201-3"
unacquired_job 21 >"$FAKE_DIR/jobs-201-1.json"
unacquired_job 21 >"$FAKE_DIR/jobs-201-2.json"
not_acquired_annotation 21
expect "unacquired failures are re-run until success" "$script" supervise o/r 201 4 60
[[ "$(paste -sd, "$FAKE_DIR/reruns")" == 201,201 ]] || { echo "FAIL: reruns" >&2; exit 1; }
[[ "$(paste -sd, "$FAKE_DIR/sleeps")" == 60,120 ]] || { echo "FAIL: backoff" >&2; exit 1; }

reset_state supervise-cap
for attempt in 1 2 3; do
  echo failure >"$FAKE_DIR/conclusion-202-$attempt"
  unacquired_job 22 >"$FAKE_DIR/jobs-202-$attempt.json"
done
not_acquired_annotation 22
expect_not "retries stop at the attempt cap" "$script" supervise o/r 202 3 1
[[ "$(wc -l <"$FAKE_DIR/reruns" | tr -d ' ')" == 2 ]] || { echo "FAIL: cap reruns" >&2; exit 1; }

reset_state supervise-real-failure
echo failure >"$FAKE_DIR/conclusion-203-1"
printf '{"jobs":[{"id":23,"conclusion":"failure","steps":[{}],"runner_name":"z"}]}\n' \
  >"$FAKE_DIR/jobs-203-1.json"
expect_not "a real failure is reported without retry" "$script" supervise o/r 203 4 1
[[ ! -f "$FAKE_DIR/reruns" ]] || { echo "FAIL: real failure was re-run" >&2; exit 1; }

reset_state supervise-refused
echo failure >"$FAKE_DIR/conclusion-204-1"
unacquired_job 24 >"$FAKE_DIR/jobs-204-1.json"
not_acquired_annotation 24
touch "$FAKE_DIR/refuse-204"
expect_not "a refused rerun still terminates at the cap" "$script" supervise o/r 204 2 1

reset_state resolve
printf 'Created workflow_dispatch event for release-x.yml at main\nhttps://github.com/o/r/actions/runs/777\n' \
  >"$FAKE_DIR/dispatch.out"
[[ "$("$script" resolve o/r release-x.yml 2026-01-01T00:00:00Z "$FAKE_DIR/dispatch.out")" == 777 ]] ||
  { echo "FAIL: resolve from dispatch output" >&2; exit 1; }
echo "ok: resolve uses the dispatched run URL"
printf '[{"databaseId":5,"createdAt":"2026-01-01T00:00:00Z"},{"databaseId":7,"createdAt":"2026-01-02T00:00:02Z"},{"databaseId":6,"createdAt":"2026-01-02T00:00:01Z"}]\n' \
  >"$FAKE_DIR/list.json"
[[ "$("$script" resolve o/r release-x.yml 2026-01-02T00:00:00Z)" == 6 ]] ||
  { echo "FAIL: resolve by polling" >&2; exit 1; }
echo "ok: resolve polls for the first run created after dispatch"
printf '[]\n' >"$FAKE_DIR/list.json"
expect_not "resolve fails when no run appears" "$script" resolve o/r release-x.yml 2026-01-02T00:00:00Z

reset_state sweep
cat >"$FAKE_DIR/runs.json" <<'EOF'
{"workflow_runs":[
  {"id":301,"conclusion":"failure","run_attempt":1,"path":".github/workflows/pr-ci.yml","head_branch":"feat/a","head_sha":"aaa"},
  {"id":302,"conclusion":"failure","run_attempt":1,"path":".github/workflows/pr-ci.yml","head_branch":"feat/a","head_sha":"aaa"},
  {"id":303,"conclusion":"cancelled","run_attempt":4,"path":".github/workflows/release-lift.yml","head_branch":"lift-v1","head_sha":"ccc"},
  {"id":304,"conclusion":"success","run_attempt":1,"path":".github/workflows/pr-ci.yml","head_branch":"feat/a","head_sha":"aaa"},
  {"id":305,"conclusion":"failure","run_attempt":1,"path":".github/workflows/retry-unacquired-runners.yml","head_branch":"main","head_sha":"ddd"},
  {"id":306,"conclusion":"failure","run_attempt":1,"path":".github/workflows/pr-ci.yml","head_branch":"feat/old","head_sha":"old"},
  {"id":307,"conclusion":"failure","run_attempt":1,"path":".github/workflows/pr-ci.yml","head_branch":"feat/gone","head_sha":"eee"},
  {"id":308,"conclusion":"cancelled","run_attempt":2,"path":".github/workflows/release-ledger.yml","head_branch":"ledger-v2","head_sha":"fff"}
]}
EOF
echo aaa >"$FAKE_DIR/commit-feat_a"
echo new >"$FAKE_DIR/commit-feat_old"
echo fff >"$FAKE_DIR/commit-ledger-v2"
for run in 306 307 308; do
  unacquired_job "${run}0" >"$FAKE_DIR/jobs-$run-1.json"
  not_acquired_annotation "${run}0"
done
unacquired_job 31 >"$FAKE_DIR/jobs-301-1.json"
not_acquired_annotation 31
printf '{"jobs":[{"id":32,"conclusion":"failure","steps":[{}],"runner_name":"w"}]}\n' \
  >"$FAKE_DIR/jobs-302-1.json"
"$script" sweep o/r 2026-01-01T00:00:00Z 4 >/dev/null
[[ "$(paste -sd, "$FAKE_DIR/reruns")" == 301,308 ]] || {
  echo "FAIL: sweep selection $(paste -sd, "$FAKE_DIR/reruns")" >&2
  exit 1
}
echo "ok: sweep re-runs only never-acquired runs whose branch or tag is still current"

expect_not "unknown modes are rejected" "$script" bogus 2>/dev/null
echo "runner retry tests passed"
