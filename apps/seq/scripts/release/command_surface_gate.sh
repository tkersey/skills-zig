#!/usr/bin/env bash
set -euo pipefail

matches_ere() {
  local pattern="$1"
  grep -E -- "$pattern" >/dev/null
}

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

platform="$(uname -s)"
hctp_product_available=false
if [[ "$platform" == "Darwin" ]]; then
  hctp_product_available=true
fi

expected="$(grep -E '\.name = "' "$SRC_LIB" | sed -E 's/.*\.name = "([^"]+)".*/\1/' | sort)"
if [[ "$hctp_product_available" != true ]]; then
  expected="$(printf '%s\n' "$expected" | grep -Ev '^(hctp-source|hylo-extract)$')"
fi
help_output="$("$BIN_PATH" --help)"
actual="$(printf '%s\n' "$help_output" | sed -n 's/^- //p' | sort)"

if [[ "$expected" != "$actual" ]]; then
  echo "command-surface mismatch between source and built binary" >&2
  echo "--- expected (src/lib.zig) ---" >&2
  printf '%s\n' "$expected" >&2
  echo "--- actual ($BIN_PATH --help) ---" >&2
  printf '%s\n' "$actual" >&2
  exit 1
fi

if ! "$BIN_PATH" --help | matches_ere '^- session-tooling$'; then
  echo "required command missing: session-tooling" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- query-diagnose$'; then
  echo "required command missing: query-diagnose" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- goal-audit$'; then
  echo "required command missing: goal-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- artifact-search$'; then
  echo "required command missing: artifact-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- workflow-overlap$'; then
  echo "required command missing: workflow-overlap" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- skill-audit$'; then
  echo "required command missing: skill-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- skill-decision-audit$'; then
  echo "required command missing: skill-decision-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- skill-contract$'; then
  echo "required command missing: skill-contract" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- skill-decision-receipt$'; then
  echo "required command missing: skill-decision-receipt" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- decision-capsule$'; then
  echo "required command missing: decision-capsule" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- capabilities$'; then
  echo "required command missing: capabilities" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- actuation-audit$'; then
  echo "required command missing: actuation-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- execution-policy-audit$'; then
  echo "required command missing: execution-policy-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- tool-audit$'; then
  echo "required command missing: tool-audit" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- memory-inventory$'; then
  echo "required command missing: memory-inventory" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- message-search$'; then
  echo "required command missing: message-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- workdir-report$'; then
  echo "required command missing: workdir-report" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- memory-provenance$'; then
  echo "required command missing: memory-provenance" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- memory-map$'; then
  echo "required command missing: memory-map" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- memory-history$'; then
  echo "required command missing: memory-history" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- plan-search$'; then
  echo "required command missing: plan-search" >&2
  exit 1
fi
if ! "$BIN_PATH" --help | matches_ere '^- reply-latency$'; then
  echo "required command missing: reply-latency" >&2
  exit 1
fi
if ! "$BIN_PATH" token-usage --help | matches_ere '--last <duration>'; then
  echo "token-usage help missing --last duration support" >&2
  exit 1
fi
if ! "$BIN_PATH" token-cost --help | matches_ere '--pricing <kind>'; then
  echo "token-cost help missing pricing mode support" >&2
  exit 1
fi
if ! "$BIN_PATH" token-cost --help | matches_ere '--model <name>'; then
  echo "token-cost help missing API model override support" >&2
  exit 1
fi
if ! "$BIN_PATH" artifact-search --help | matches_ere '--contains-any <csv>'; then
  echo "artifact-search help missing --contains-any support" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | matches_ere 'term-summary'; then
  echo "workflow-audit help missing term-summary mode" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | matches_ere 'cohort-report'; then
  echo "workflow-audit help missing cohort-report mode" >&2
  exit 1
fi
if ! "$BIN_PATH" workflow-audit --help | matches_ere '--term-group <name=csv>'; then
  echo "workflow-audit help missing --term-group support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-blocks --help | matches_ere '--mode blocks|term-counts|term-summary'; then
  echo "skill-blocks help missing native term-analysis modes" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-blocks --help | matches_ere '--term-group <name=csv>'; then
  echo "skill-blocks help missing --term-group support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-decision-audit --help | matches_ere '--contract <path>'; then
  echo "skill-decision-audit help missing --contract support" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-decision-audit --help | matches_ere 'tune-packet'; then
  echo "skill-decision-audit help missing tune-packet mode" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-contract --help | matches_ere 'validate --file'; then
  echo "skill-contract help missing validate surface" >&2
  exit 1
fi
if ! "$BIN_PATH" skill-decision-receipt --help | matches_ere 'validate --file'; then
  echo "skill-decision-receipt help missing validate surface" >&2
  exit 1
fi
if ! "$BIN_PATH" decision-capsule --help | matches_ere '--decision-id <id>'; then
  echo "decision-capsule help missing decision selector support" >&2
  exit 1
fi
if ! "$BIN_PATH" decision-capsule --help | matches_ere 'capsule|candidates|anchors|validate'; then
  echo "decision-capsule help missing mode surface" >&2
  exit 1
fi
if ! "$BIN_PATH" execution-policy-audit --help | matches_ere '--mode summary|runs|policies|transitions|calibration|regret|proof|report'; then
  echo "execution-policy-audit help missing mode surface" >&2
  exit 1
fi
if ! "$BIN_PATH" execution-policy-audit --help | matches_ere '--policy-root <path>'; then
  echo "execution-policy-audit help missing policy root support" >&2
  exit 1
fi
capabilities_json="$("$BIN_PATH" capabilities --format json)"
if [[ "$hctp_product_available" == true ]]; then
  for cmd in hctp-source hylo-extract; do
    if ! printf '%s\n' "$help_output" | matches_ere "^- ${cmd}$"; then
      echo "required macOS HCTP command missing: ${cmd}" >&2
      exit 1
    fi
  done
  for feature in \
    hctp_source_selection_v1 \
    hctp_source_route_admission_v1 \
    hctp_independence_clusters_v1 \
    hctp_sealed_case_v1 \
    hctp_materializer_v1 \
    hctp_source_materialization_v1 \
    hctp_source_selection_opening_fd_v1 \
    hctp_historical_profile_v1 \
    hctp_case_blind_source_profile_fd_v1 \
    hylo_extract_v1
  do
    if ! printf '%s\n' "$capabilities_json" | matches_ere "\"${feature}\": true"; then
      echo "macOS capabilities missing ${feature}=true" >&2
      exit 1
    fi
  done
  hctp_source_help="$("$BIN_PATH" hctp-source --help)"
  for flag in \
    '--manifest-fd N' \
    '--source-signing-seed-fd N' \
    '--sealed-dir DIR' \
    '--seal-key-output-fd N' \
    '--seal-key-fd N' \
    '--visible-output-fd N' \
    '--source-profile-output-fd N' \
    '--source-selection-opening-fd N' \
    '--signing-seed-fd N'
  do
    if ! printf '%s\n' "$hctp_source_help" | matches_ere "$flag"; then
      echo "hctp-source help missing protected compile/materialize flag: ${flag}" >&2
      exit 1
    fi
  done
  if ! printf '%s\n' "$hctp_source_help" | matches_ere 'hylo-source-selection-opening/v1'; then
    echo "hctp-source help missing the v2 protected source-selection opening contract" >&2
    exit 1
  fi
  hylo_extract_help="$("$BIN_PATH" hylo-extract --help)"
  for flag in \
    '--target-root DIR' \
    '--output-root DIR' \
    '--sealed-root DIR' \
    '--seal-key-output-fd N'
  do
    if ! printf '%s\n' "$hylo_extract_help" | matches_ere "$flag"; then
      echo "hylo-extract help missing protected target/output flag: ${flag}" >&2
      exit 1
    fi
  done
else
  for cmd in hctp-source hylo-extract; do
    if printf '%s\n' "$help_output" | matches_ere "^- ${cmd}$"; then
      echo "non-macOS command surface exposes ${cmd}" >&2
      exit 1
    fi
  done
  for feature in \
    hctp_source_selection_v1 \
    hctp_source_route_admission_v1 \
    hctp_independence_clusters_v1 \
    hctp_sealed_case_v1 \
    hctp_materializer_v1 \
    hctp_source_materialization_v1 \
    hctp_source_selection_opening_fd_v1 \
    hctp_historical_profile_v1 \
    hctp_case_blind_source_profile_fd_v1 \
    hylo_extract_v1
  do
    if printf '%s\n' "$capabilities_json" | matches_ere "\"${feature}\""; then
      echo "non-macOS capabilities expose ${feature}" >&2
      exit 1
    fi
  done
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"skill_decision_audit": true'; then
  echo "capabilities missing skill_decision_audit=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"decision_capsule_v1": true'; then
  echo "capabilities missing decision_capsule_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"historical_decisions_dataset_v1": true'; then
  echo "capabilities missing historical_decisions_dataset_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"actuation_audit_v1": true'; then
  echo "capabilities missing actuation_audit_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"actuation_compaction_resume_v1": true'; then
  echo "capabilities missing actuation_compaction_resume_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"execution_policy_audit_v1": true'; then
  echo "capabilities missing execution_policy_audit_v1=true" >&2
  exit 1
fi
if ! "$BIN_PATH" capabilities --format json | matches_ere '"policy_transition_dataset_v1": true'; then
  echo "capabilities missing policy_transition_dataset_v1=true" >&2
  exit 1
fi
for feature in \
  ledger_artifact_root_v1
do
  if ! "$BIN_PATH" capabilities --format json | matches_ere "\"${feature}\": true"; then
    echo "capabilities missing ${feature}=true" >&2
    exit 1
  fi
done
if ! "$BIN_PATH" dataset-schema --dataset execution_policy_transitions --format json | matches_ere '"field": "transition_audits"'; then
  echo "execution_policy_transitions schema missing transition_audits" >&2
  exit 1
fi
if ! "$BIN_PATH" query --root /tmp --spec '{"dataset":"execution_policy_runs","params":{"path":"/dev/null"},"select":["runtime_state","verdict"],"format":"json"}' | matches_ere '"runtime_state"'; then
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
  if ! "$BIN_PATH" capabilities --format json | matches_ere "\"${feature}\": true"; then
    echo "capabilities missing ${feature}=true" >&2
    exit 1
  fi
done
if ! "$BIN_PATH" workflow-overlap --help | matches_ere '--mode summary|sessions'; then
  echo "workflow-overlap help missing summary/sessions modes" >&2
  exit 1
fi
if ! "$BIN_PATH" adjudication-audit --help | matches_ere '--mode summary|rows|report'; then
  echo "adjudication-audit help missing native summary/rows/report modes" >&2
  exit 1
fi
for cmd in skill-audit tool-audit memory-inventory message-search workdir-report; do
  if ! "$BIN_PATH" --help | matches_ere "^- ${cmd}$"; then
    echo "required command missing: ${cmd}" >&2
    exit 1
  fi
done

echo "command-surface gate passed for $BIN_PATH"
