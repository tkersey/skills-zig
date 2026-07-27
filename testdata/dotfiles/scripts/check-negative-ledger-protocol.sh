#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"

dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
ledger_bin=${LEDGER_BIN:-"$skills_zig_root/zig-out/bin/ledger-v1-candidate"}
definition="$dotfiles_root/codex/skills/negative-ledger/definitions/ledger/negative-evidence-protocol.json"

command -v jq >/dev/null
command -v "$ledger_bin" >/dev/null
[[ -f "$definition" && ! -L "$definition" ]]

scratch=$(mktemp -d)
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
jq -c . "$scratch/status.json" >>"$repo/.ledger/negative-ledger/events.jsonl"
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

assert_ledger_doctor_slot_state \
  "$ledger_bin" "$definition" "$repo" events \
  current true 0 "$scratch/doctor-current.json"

jq -c '.event_id = "invalid"' "$scratch/capture.json" \
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

printf 'negative-ledger protocol conformance passed: generated=2 invalid=2 bindings=1\n'
