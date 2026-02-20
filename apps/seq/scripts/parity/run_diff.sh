#!/usr/bin/env bash
set -euo pipefail

ROOT="${HOME}/.codex/sessions"
MATRIX="scripts/parity/matrix.json"
ZIG_BIN="./zig-out/bin/seq"
WORK_DIR=".zig-cache/parity"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --matrix) MATRIX="$2"; shift 2 ;;
    --zig-bin) ZIG_BIN="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

if [[ ! -f "$MATRIX" ]]; then
  echo "missing matrix: $MATRIX" >&2
  exit 66
fi

mkdir -p "$WORK_DIR"

PY_ORACLE="$(jq -r '.python_oracle' "$MATRIX")"
if [[ -z "$PY_ORACLE" || "$PY_ORACLE" == "null" ]]; then
  echo "matrix missing python_oracle" >&2
  exit 65
fi

normalize_output() {
  local in_file="$1"
  local out_file="$2"
  if [[ ! -s "$in_file" ]]; then
    : >"$out_file"
    return
  fi
  if jq -e . "$in_file" >/dev/null 2>&1; then
    jq -cS . "$in_file" >"$out_file"
  else
    sed -e 's/[[:space:]]*$//' "$in_file" >"$out_file"
  fi
}

failures=0
results_json="$WORK_DIR/results.jsonl"
: >"$results_json"

while IFS= read -r case_json; do
  id="$(jq -r '.id' <<<"$case_json")"
  kind="$(jq -r '.kind' <<<"$case_json")"

  zig_out="$WORK_DIR/${id}.zig.out"
  py_out="$WORK_DIR/${id}.py.out"
  zig_norm="$WORK_DIR/${id}.zig.norm"
  py_norm="$WORK_DIR/${id}.py.norm"
  diff_file="$WORK_DIR/${id}.diff"

  set +e
  if [[ "$kind" == "query_spec" ]]; then
    spec_path="$(jq -r '.spec' <<<"$case_json")"
    "$ZIG_BIN" query --root "$ROOT" --spec "@$spec_path" --output "$zig_out" >/dev/null 2>"$WORK_DIR/${id}.zig.err"
    zig_code=$?
    uv run python "$PY_ORACLE" query --root "$ROOT" --spec "@$spec_path" --output "$py_out" >/dev/null 2>"$WORK_DIR/${id}.py.err"
    py_code=$?
  elif [[ "$kind" == "command" ]]; then
    cmd_args=()
    while IFS= read -r arg; do
      cmd_args+=("$arg")
    done < <(jq -r '.args[]' <<<"$case_json")
    "$ZIG_BIN" "${cmd_args[@]}" --root "$ROOT" --output "$zig_out" >/dev/null 2>"$WORK_DIR/${id}.zig.err"
    zig_code=$?
    uv run python "$PY_ORACLE" "${cmd_args[@]}" --root "$ROOT" --output "$py_out" >/dev/null 2>"$WORK_DIR/${id}.py.err"
    py_code=$?
  else
    echo "unsupported case kind: $kind" >&2
    exit 65
  fi
  set -e

  case_pass=1
  reason="ok"

  if [[ $zig_code -ne $py_code ]]; then
    case_pass=0
    reason="exit_code_mismatch"
  elif [[ $zig_code -eq 0 ]]; then
    normalize_output "$zig_out" "$zig_norm"
    normalize_output "$py_out" "$py_norm"
    if ! diff -u "$py_norm" "$zig_norm" >"$diff_file"; then
      case_pass=0
      reason="output_mismatch"
    fi
  fi

  if [[ $case_pass -eq 0 ]]; then
    failures=$((failures + 1))
  fi

  jq -nc \
    --arg id "$id" \
    --arg kind "$kind" \
    --arg reason "$reason" \
    --argjson pass "$case_pass" \
    --argjson zig_code "$zig_code" \
    --argjson py_code "$py_code" \
    '{id:$id,kind:$kind,pass:($pass==1),reason:$reason,zig_code:$zig_code,py_code:$py_code}' \
    >>"$results_json"
done < <(jq -c '.required[]' "$MATRIX")

passed=$(( $(jq -s '[.[] | select(.pass==true)] | length' "$results_json") ))
total=$(( $(jq -s 'length' "$results_json") ))

jq -n \
  --arg root "$ROOT" \
  --arg matrix "$MATRIX" \
  --arg zig_bin "$ZIG_BIN" \
  --arg py_oracle "$PY_ORACLE" \
  --argjson total "$total" \
  --argjson passed "$passed" \
  --argjson failed "$failures" \
  --arg results_file "$results_json" \
  '{root:$root,matrix:$matrix,zig_bin:$zig_bin,python_oracle:$py_oracle,total:$total,passed:$passed,failed:$failed,results_file:$results_file}'

if [[ $failures -ne 0 ]]; then
  exit 2
fi
