#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_LIB="$ROOT_DIR/src/lib.zig"
BIN_PATH="${1:-$ROOT_DIR/zig-out/bin/seq}"

if [[ ! -f "$SRC_LIB" ]]; then
  echo "source file not found: $SRC_LIB" >&2
  exit 1
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "binary not found/executable: $BIN_PATH" >&2
  echo "build first: (cd $ROOT_DIR && zig build -Doptimize=ReleaseSafe)" >&2
  exit 1
fi

expected="$(rg -N '\.name = "' "$SRC_LIB" | sed -E 's/.*\.name = "([^"]+)".*/\1/' | sort)"
actual="$("$BIN_PATH" --help | sed -n 's/^- //p' | sort)"

if [[ "$expected" != "$actual" ]]; then
  echo "command-surface mismatch between source and built binary" >&2
  echo "--- expected (src/lib.zig) ---" >&2
  printf '%s\n' "$expected" >&2
  echo "--- actual ($BIN_PATH --help) ---" >&2
  printf '%s\n' "$actual" >&2
  exit 1
fi

if ! "$BIN_PATH" --help | rg -q '^- session-tooling$'; then
  echo "required command missing: session-tooling" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- query-diagnose$'; then
  echo "required command missing: query-diagnose" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- goal-audit$'; then
  echo "required command missing: goal-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- artifact-search$'; then
  echo "required command missing: artifact-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- workflow-overlap$'; then
  echo "required command missing: workflow-overlap" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- skill-audit$'; then
  echo "required command missing: skill-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- skill-decision-audit$'; then
  echo "required command missing: skill-decision-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- skill-contract$'; then
  echo "required command missing: skill-contract" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- skill-decision-receipt$'; then
  echo "required command missing: skill-decision-receipt" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- decision-capsule$'; then
  echo "required command missing: decision-capsule" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- capabilities$'; then
  echo "required command missing: capabilities" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- actuation-audit$'; then
  echo "required command missing: actuation-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- execution-policy-audit$'; then
  echo "required command missing: execution-policy-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- tool-audit$'; then
  echo "required command missing: tool-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-inventory$'; then
  echo "required command missing: memory-inventory" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- message-search$'; then
  echo "required command missing: message-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- workdir-report$'; then
  echo "required command missing: workdir-report" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-provenance$'; then
  echo "required command missing: memory-provenance" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-map$'; then
  echo "required command missing: memory-map" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- memory-history$'; then
  echo "required command missing: memory-history" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- plan-search$'; then
  echo "required command missing: plan-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | rg -q '^- reply-latency$'; then
  echo "required command missing: reply-latency" >&2
  exit 1
fi
if ! "$BIN_PATH" token-usage --help | rg -q -- '--last <duration>'; then
  echo "token-usage help missing --last duration support" >&2
  exit 1
fi
if ! "$BIN_PATH" token-cost --help | rg -q -- '--pricing <kind>'; then
  echo "token-cost help missing pricing mode support" >&2
  exit 1
fi
if ! "$BIN_PATH" token-cost --help | rg -q -- '--model <name>'; then
  echo "token-cost help missing API model override support" >&2
  exit 1
fi
if ! "$BIN_PATH" artifact-search --help | rg -q -- '--contains-any <csv>'; then
  echo "artifact-search help missing --contains-any support" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | rg -q -- 'term-summary'; then
  echo "workflow-audit help missing term-summary mode" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | rg -q -- 'cohort-report'; then
  echo "workflow-audit help missing cohort-report mode" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | rg -q -- '--term-group <name=csv>'; then
  echo "workflow-audit help missing --term-group support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-blocks --help | rg -q -- '--mode blocks|term-counts|term-summary'; then
  echo "skill-blocks help missing native term-analysis modes" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-blocks --help | rg -q -- '--term-group <name=csv>'; then
  echo "skill-blocks help missing --term-group support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-decision-audit --help | rg -q -- '--contract <path>'; then
  echo "skill-decision-audit help missing --contract support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-decision-audit --help | rg -q -- 'tune-packet'; then
  echo "skill-decision-audit help missing tune-packet mode" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-contract --help | rg -q -- 'validate --file'; then
  echo "skill-contract help missing validate surface" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-decision-receipt --help | rg -q -- 'validate --file'; then
  echo "skill-decision-receipt help missing validate surface" >&2
  exit 1
fi
if ! "$BIN_PATH" decision-capsule --help | rg -q -- '--decision-id <id>'; then
  echo "decision-capsule help missing decision selector support" >&2
  exit 1
fi
if ! "$BIN_PATH" decision-capsule --help | rg -q -- 'capsule|candidates|anchors|validate'; then
  echo "decision-capsule help missing mode surface" >&2
  exit 1
fi
if ! "$BIN_PATH" execution-policy-audit --help | rg -q -- '--mode summary|runs|policies|transitions|calibration|regret|proof|report'; then
  echo "execution-policy-audit help missing mode surface" >&2
  exit 1
fi
if ! "$BIN_PATH" execution-policy-audit --help | rg -q -- '--policy-root <path>'; then
  echo "execution-policy-audit help missing policy root support" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"skill_decision_audit": true'; then
  echo "capabilities missing skill_decision_audit=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"decision_capsule_v1": true'; then
  echo "capabilities missing decision_capsule_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"historical_decisions_dataset_v1": true'; then
  echo "capabilities missing historical_decisions_dataset_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"actuation_audit_v1": true'; then
  echo "capabilities missing actuation_audit_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"actuation_compaction_resume_v1": true'; then
  echo "capabilities missing actuation_compaction_resume_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"execution_policy_audit_v1": true'; then
  echo "capabilities missing execution_policy_audit_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | rg -q -- '"policy_transition_dataset_v1": true'; then
  echo "capabilities missing policy_transition_dataset_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" dataset-schema --dataset execution_policy_transitions --format json | rg -q -- '"field": "transition_audits"'; then
  echo "execution_policy_transitions schema missing transition_audits" >&2
  exit 1
fi
if ! "$BIN_PATH" query --root /tmp --spec '{"dataset":"execution_policy_runs","params":{"path":"/dev/null"},"select":["runtime_state","verdict"],"format":"json"}' | rg -q -- '"runtime_state"'; then
  echo "execution_policy_runs query projection failed" >&2
  exit 1
fi
for feature in \
  resolve_acceptance_contract_v2 \
  resolve_review_batch_v1 \
  resolve_review_aperture_v1 \
  resolve_counterexample_v1 \
  resolve_counterexample_basis_v2 \
  resolve_review_potential_v1 \
  resolve_intent_closed_audit_v1 \
  internal_context_not_success_v1
do
  if ! "$BIN_PATH" capabilities --format json | rg -q -- "\"${feature}\": true"; then
    echo "capabilities missing ${feature}=true" >&2
    exit 1
  fi
done
if ! "$BIN_PATH" workflow-overlap --help | rg -q -- '--mode summary|sessions'; then
  echo "workflow-overlap help missing summary/sessions modes" >&2
  exit 1
fi
if ! "$BIN_PATH" adjudication-audit --help | rg -q -- '--mode summary|rows|report'; then
  echo "adjudication-audit help missing native summary/rows/report modes" >&2
  exit 1
fi
for cmd in skill-audit tool-audit memory-inventory message-search workdir-report; do
  if ! "$BIN_PATH" --help | rg -q "^- ${cmd}$"; then
    echo "required command missing: ${cmd}" >&2
    exit 1
  fi
done

echo "command-surface gate passed for $BIN_PATH"
