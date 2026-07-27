#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"

dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
ledger_bin=${LEDGER_BIN:-"$skills_zig_root/zig-out/bin/ledger"}
definition="$dotfiles_root/codex/skills/negative-ledger/definitions/ledger/negative-evidence-protocol.json"

command -v jq >/dev/null
command -v "$ledger_bin" >/dev/null
[[ -f "$definition" && ! -L "$definition" ]]

scratch=$(mktemp -d /private/tmp/ledger-negative-conformance.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/.ledger/negative-ledger"
repo=$(cd "$repo" && pwd -P)

jq -nc \
  '{
    v: 3,
    event: "capture",
    event_id: "NLE-aaaaaaaaaaaaaaaaaaaaaaaa",
    timestamp: "2026-07-26T00:00:00Z",
    neg_id: "NEG-000001",
    status: "need-evidence",
    record: {
      artifact_state_id: "",
      artifact_state_label: "",
      repository_id: "owner/repo"
    }
  }' >"$scratch/capture.json"
jq -nc \
  '{
    v: 3,
    event: "status",
    event_id: "NLE-bbbbbbbbbbbbbbbbbbbbbbbb",
    timestamp: "2026-07-26T00:00:01Z",
    neg_id: "NEG-000001",
    from: "need-evidence",
    to: "superseded",
    status: "superseded",
    reason: "replaced by a complete capture",
    criterion_ids: [],
    criterion_changes: [],
    source_refs: [
      {
        kind: "test",
        ref: "generated:negative-ledger-protocol"
      }
    ]
  }' >"$scratch/status.json"

for event in "$scratch/capture.json" "$scratch/status.json"; do
  "$ledger_bin" validate \
    --definition "$definition" \
    --input "event=$event" \
    --format json |
    jq -e \
      '.valid == true and
       .authority_granted == false and
       .storage_mutated == false' >/dev/null
done

jq '.status = "active"' "$scratch/status.json" >"$scratch/status-invalid.json"
set +e
"$ledger_bin" validate \
  --definition "$definition" \
  --input "event=$scratch/status-invalid.json" \
  --format json >"$scratch/status-invalid-result.json"
invalid_exit=$?
set -e
[[ "$invalid_exit" -eq 2 ]]
jq -e '.valid == false' "$scratch/status-invalid-result.json" >/dev/null

jq -c . "$scratch/capture.json" >"$repo/.ledger/negative-ledger/events.jsonl"
store_digest_before=$(shasum -a 256 "$repo/.ledger/negative-ledger/events.jsonl" | awk '{print $1}')

"$ledger_bin" transact \
  --definition "$definition" \
  --operation bind-existing \
  --repo "$repo" \
  --format json >"$scratch/bind.json"
jq -e \
  '.operation == "bind-existing" and
   .effects[0].result == "bound" and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  "$scratch/bind.json" >/dev/null
store_digest_after=$(shasum -a 256 "$repo/.ledger/negative-ledger/events.jsonl" | awk '{print $1}')
[[ "$store_digest_before" == "$store_digest_after" ]]

"$ledger_bin" transact \
  --definition "$definition" \
  --operation append-event \
  --repo "$repo" \
  --input "event=$scratch/status.json" \
  --format json >"$scratch/append.json"
jq -e \
  '.operation == "append-event" and
   .effects[0].result == "appended" and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  "$scratch/append.json" >/dev/null
expected_status=$(jq -cS . "$scratch/status.json")
actual_status=$(tail -n 1 "$repo/.ledger/negative-ledger/events.jsonl")
[[ "$expected_status" == "$actual_status" ]]

assert_ledger_doctor_slot_state \
  "$ledger_bin" "$definition" "$repo" events \
  current true 0 "$scratch/doctor-current.json"

"$ledger_bin" project \
  --definition "$definition" \
  --projection current-records \
  --repo "$repo" \
  --payload-only \
  --format json >"$scratch/current-states.json"
jq -e --slurpfile capture "$scratch/capture.json" \
  'length == 1 and
   .[0].neg_id == "NEG-000001" and
   .[0].status == "superseded" and
   .[0].source_event_count == 2 and
   .[0].record == $capture[0].record' \
  "$scratch/current-states.json" >/dev/null

transaction_repo="$scratch/transaction-repo"
mkdir -p "$transaction_repo"
transaction_repo=$(cd "$transaction_repo" && pwd -P)
jq -nc \
  '{
    record: {
      record_version: "NER-v2",
      kind: "realization_route",
      route_id: "route-a",
      hypothesis: "The bounded route did not work.",
      source_refs: [{kind: "test", ref: "generated:capture"}],
      status: "need-evidence",
      artifact_state_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      artifact_state_label: "fixture",
      repository_id: "owner/repo"
    }
  }' >"$scratch/capture-request.json"
"$ledger_bin" transact \
  --definition "$definition" \
  --operation capture \
  --repo "$transaction_repo" \
  --input "capture=$scratch/capture-request.json" \
  --format json >"$scratch/capture-result-1.json"
jq \
  '.record.route_id = "route-b" |
   .record.hypothesis = "A second bounded route did not work."' \
  "$scratch/capture-request.json" >"$scratch/capture-request-2.json"
"$ledger_bin" transact \
  --definition "$definition" \
  --operation capture \
  --repo "$transaction_repo" \
  --input "capture=$scratch/capture-request-2.json" \
  --format json >"$scratch/capture-result-2.json"
jq -e \
  '.operation == "capture" and
   .generated_outputs.neg_id == "NEG-000001" and
   (.generated_outputs.event_id | test("^NLE-[a-f0-9]{24}$"))' \
  "$scratch/capture-result-1.json" >/dev/null
jq -e \
  '.operation == "capture" and
   .generated_outputs.neg_id == "NEG-000002"' \
  "$scratch/capture-result-2.json" >/dev/null

jq -nc \
  '{
    neg_id: "NEG-000001",
    from: "need-evidence",
    to: "stale",
    reason: "The fixture artifact changed.",
    criterion_ids: [],
    criterion_changes: [],
    source_refs: [{kind: "test", ref: "generated:transition"}]
  }' >"$scratch/transition-request.json"
"$ledger_bin" transact \
  --definition "$definition" \
  --operation transition \
  --repo "$transaction_repo" \
  --input "transition=$scratch/transition-request.json" \
  --format json >"$scratch/transition-result.json"
jq -e \
  '.operation == "transition" and
   (.returned_content | fromjson |
    .from == "need-evidence" and .to == "stale" and .status == "stale")' \
  "$scratch/transition-result.json" >/dev/null
assert_ledger_doctor_slot_state \
  "$ledger_bin" "$definition" "$transaction_repo" events \
  current true 0 "$scratch/doctor-transaction.json"

jq -c \
  '.event_id = "NLE-cccccccccccccccccccccccc" |
   .from = "active" |
   .to = "stale" |
   .status = "stale"' \
  "$scratch/status.json" \
  >>"$repo/.ledger/negative-ledger/events.jsonl"
set +e
"$ledger_bin" doctor \
  --definition "$definition" \
  --repo "$repo" \
  --format json >"$scratch/doctor-invalid.json"
doctor_exit=$?
set -e
[[ "$doctor_exit" -eq 2 ]]
jq -e \
  '.healthy == false and
   any(.slots[]; .name == "events" and .status == "invalid")' \
  "$scratch/doctor-invalid.json" >/dev/null

gate_repo="$scratch/gate-repo"
mkdir -p "$gate_repo/.ledger/negative-ledger"
gate_repo=$(cd "$gate_repo" && pwd -P)
artifact="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
jq -nc \
  --arg artifact "$artifact" \
  '{
    v: 3,
    event: "capture",
    event_id: "NLE-cccccccccccccccccccccccc",
    timestamp: "2026-07-26T00:00:02Z",
    neg_id: "NEG-000002",
    status: "active",
    record: {
      record_version: "NER-v2",
      kind: "realization_route",
      hypothesis: "The selected route preserves the observed signal.",
      route_id: "route-a",
      artifact_state_id: $artifact,
      artifact_state_label: "fixture",
      repository_id: "owner/repo",
      attempted_change: "Apply route A.",
      observed_outcome: "The measured signal regressed.",
      exclusion_scope: "route",
      exclusion_rule: "Do not apply route A to this exact artifact.",
      failure_class: "local-regression",
      confidence: "high",
      source_refs: [
        {
          kind: "test",
          ref: "generated:negative-ledger-route-gate"
        }
      ],
      applicability_conditions: ["The artifact digest is unchanged."],
      reopening_criteria: [
        {
          id: "artifact-changed",
          condition: "The artifact digest changes."
        }
      ],
      next_search_hint: "Select a route outside the excluded family."
    }
  }' >"$scratch/gate-event.json"
jq -c . "$scratch/gate-event.json" \
  >"$gate_repo/.ledger/negative-ledger/events.jsonl"
"$ledger_bin" transact \
  --definition "$definition" \
  --operation bind-existing \
  --repo "$gate_repo" \
  --format json >"$scratch/gate-bind.json"

set +e
"$ledger_bin" project \
  --definition "$definition" \
  --projection route-gate \
  --repo "$gate_repo" \
  --param "artifact=$artifact" \
  --param "identity=route-a" \
  --format json >"$scratch/gate-hit.json"
gate_hit_exit=$?
"$ledger_bin" project \
  --definition "$definition" \
  --projection route-gate \
  --repo "$gate_repo" \
  --param "artifact=$artifact" \
  --param "identity=route-b" \
  --format json >"$scratch/gate-miss.json"
gate_miss_exit=$?
"$ledger_bin" project \
  --definition "$definition" \
  --projection route-gate \
  --repo "$gate_repo" \
  --param "artifact=$artifact" \
  --format json >"$scratch/gate-invalid.json"
gate_invalid_exit=$?
set -e
[[ "$gate_hit_exit" -eq 2 ]]
[[ "$gate_miss_exit" -eq 0 ]]
[[ "$gate_invalid_exit" -eq 3 ]]
jq -e \
  '.exit_code == 2 and
   .stats.records_scanned == 1 and
   .stats.records_matched == 1 and
   .data[0].neg_id == "NEG-000002"' \
  "$scratch/gate-hit.json" >/dev/null
jq -e \
  '.exit_code == 0 and
   .stats.records_scanned == 1 and
   .stats.records_matched == 0 and
   .data == []' \
  "$scratch/gate-miss.json" >/dev/null
jq -e \
  '.schema == "ledger-projection-error/v1" and
   .code == "MissingProjectionParameter" and
   .exit_code == 3 and
   .authority_granted == false and
   .storage_mutated == false' \
  "$scratch/gate-invalid.json" >/dev/null

printf 'negative-ledger protocol conformance passed: generated=3 invalid=3 bindings=2 transactions=4 projections=3 route_cases=3\n'
