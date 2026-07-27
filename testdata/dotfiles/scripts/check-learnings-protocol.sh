#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
skills_zig_root=$(cd "$script_dir/../../.." && pwd -P)
source "$script_dir/lib/definition-cases.sh"

dotfiles_root=${DOTFILES_ROOT:-"$HOME/.dotfiles"}
dotfiles_root=$(git -C "$dotfiles_root" rev-parse --show-toplevel)
ledger_bin=${LEDGER_BIN:-"$skills_zig_root/zig-out/bin/ledger"}
definition="$dotfiles_root/codex/skills/learnings/definitions/ledger/learnings-protocol.json"
memory_definition="$dotfiles_root/codex/skills/memory-source-notes/definitions/ledger/learnings-memory-note-payload.json"

command -v jq >/dev/null
command -v "$ledger_bin" >/dev/null
[[ -f "$definition" && ! -L "$definition" ]]
[[ -f "$memory_definition" && ! -L "$memory_definition" ]]

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo"
repo=$(cd "$repo" && pwd -P)

jq -nc \
  '{
    record: {
      status: "do_more",
      learning: "When evidence says café, preserve the stored bytes.",
      evidence: ["test:generated-learning"],
      application: "Compare the source and projected bytes.",
      context: {
        repo: "owner/repo",
        branch: "main",
        paths: ["src/learning.zig"]
      },
      source: "ledger:learnings",
      tags: ["parity"],
      related_ids: []
    }
  }' >"$scratch/submission.json"

"$ledger_bin" validate \
  --definition "$definition" \
  --input "submission=$scratch/submission.json" \
  --format json >"$scratch/validate.json"
jq -e \
  '.valid == true and
   .authority_granted == false and
   .storage_mutated == false' \
  "$scratch/validate.json" >/dev/null

jq '.record.evidence = []' \
  "$scratch/submission.json" >"$scratch/invalid-submission.json"
set +e
"$ledger_bin" validate \
  --definition "$definition" \
  --input "submission=$scratch/invalid-submission.json" \
  --format json >"$scratch/invalid-result.json"
invalid_exit=$?
set -e
[[ "$invalid_exit" -eq 2 ]]
jq -e '.valid == false' "$scratch/invalid-result.json" >/dev/null

"$ledger_bin" transact \
  --definition "$definition" \
  --operation capture \
  --repo "$repo" \
  --input "submission=$scratch/submission.json" \
  --format json >"$scratch/capture.json"
jq -e \
  '.operation == "capture" and
   .effects[0].result == "appended" and
   .generated_outputs.fingerprint == "caf509bdb7b53699" and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  "$scratch/capture.json" >/dev/null

captured_at=$(jq -r '.generated_outputs.captured_at' "$scratch/capture.json")
fingerprint=$(jq -r '.generated_outputs.fingerprint' "$scratch/capture.json")
learning_id=$(jq -r '.generated_outputs.learning_id' "$scratch/capture.json")
compact_timestamp=${captured_at//[-:]/}
[[ "$learning_id" == "lrn-$compact_timestamp-${fingerprint:0:8}" ]]

jq -c \
  --arg captured_at "$captured_at" \
  --arg fingerprint "$fingerprint" \
  --arg learning_id "$learning_id" \
  '
    .record as $record |
    {
      id: $learning_id,
      captured_at: $captured_at,
      status: $record.status,
      learning: $record.learning,
      evidence: $record.evidence,
      application: $record.application,
      context: $record.context,
      source: $record.source,
      fingerprint: $fingerprint,
      tags: $record.tags,
      related_ids: $record.related_ids
    }
  ' \
  "$scratch/submission.json" >"$scratch/expected-record.json"

jq -a -nc \
  --arg learning_id "$learning_id" \
  --slurpfile record "$scratch/expected-record.json" \
  '{
    v: 1,
    source: "learnings",
    event: "learning.capture",
    learning_id: $learning_id,
    status: $record[0].status,
    record: $record[0]
  }' >"$scratch/expected-event-lowercase-escapes.jsonl"
sed 's/\\u00e9/\\u00E9/g' \
  "$scratch/expected-event-lowercase-escapes.jsonl" \
  >"$scratch/expected-event.jsonl"

cmp -s \
  "$scratch/expected-event.jsonl" \
  "$repo/.ledger/learnings/events.jsonl"
jq -r '.returned_content' "$scratch/capture.json" \
  >"$scratch/returned-event.jsonl"
cmp -s \
  "$scratch/expected-event.jsonl" \
  "$scratch/returned-event.jsonl"

store_digest_before=$(
  shasum -a 256 "$repo/.ledger/learnings/events.jsonl" |
    awk '{print $1}'
)
"$ledger_bin" transact \
  --definition "$definition" \
  --operation capture \
  --repo "$repo" \
  --input "submission=$scratch/submission.json" \
  --format json >"$scratch/duplicate.json"
jq -e \
  '.operation == "capture" and
   .effects[0].result == "idempotent" and
   .transaction_id == null and
   .semantic_authority_granted == false and
   .storage_mutated == false' \
  "$scratch/duplicate.json" >/dev/null
store_digest_after=$(
  shasum -a 256 "$repo/.ledger/learnings/events.jsonl" |
    awk '{print $1}'
)
[[ "$store_digest_before" == "$store_digest_after" ]]
[[ "$(wc -l <"$repo/.ledger/learnings/events.jsonl")" -eq 1 ]]

assert_ledger_doctor_slot_state \
  "$ledger_bin" "$definition" "$repo" events \
  current true 0 "$scratch/doctor-current.json"

"$ledger_bin" project \
  --definition "$definition" \
  --projection record \
  --repo "$repo" \
  --param "id=$learning_id" \
  --payload-only \
  --format json >"$scratch/record.json"
cmp -s "$scratch/expected-record.json" "$scratch/record.json"

jq -c \
  --arg fingerprint "$fingerprint" \
  --arg learning_id "$learning_id" \
  '
    .record as $record |
    {
      operation: "assert",
      authority: "ledger-cli",
      summary: ("Admit " + $learning_id + " for Phase 2 consideration."),
      scope: {
        kind: "repo",
        repo: $record.context.repo,
        paths: $record.context.paths
      },
      source_refs: [
        {
          kind: "learning",
          ref: (".ledger/learnings/events.jsonl#" + $learning_id),
          summary: "Canonical learning row"
        }
      ],
      related_ids: $record.related_ids,
      supersedes_id: null,
      payload: {
        learning_id: $learning_id,
        learning_status: $record.status,
        repo: $record.context.repo,
        source_path: ".ledger/learnings/events.jsonl",
        decision_delta: $record.learning,
        evidence_snapshot: $record.evidence,
        future_behavior: $record.application,
        verification:
          "Re-check the canonical row and evidence snapshot before applying this learning.",
        tags: $record.tags,
        canonical_fingerprint: $fingerprint
      }
    }
  ' \
  "$scratch/submission.json" >"$scratch/expected-memory-note.json"
"$ledger_bin" project \
  --definition "$definition" \
  --projection memory-note \
  --repo "$repo" \
  --param "id=$learning_id" \
  --payload-only \
  --format json >"$scratch/memory-note.json"
cmp -s "$scratch/expected-memory-note.json" "$scratch/memory-note.json"

"$ledger_bin" validate \
  --definition "$memory_definition" \
  --input "note=$scratch/memory-note.json" \
  --format json >"$scratch/memory-note-validation.json"
jq -e \
  '.definition.id ==
     "memory-source-notes/learnings-memory-note-payload" and
   .valid == true and
   .authority_granted == false and
   .storage_mutated == false' \
  "$scratch/memory-note-validation.json" >/dev/null

bound_repo="$scratch/bound-repo"
mkdir -p "$bound_repo/.ledger/learnings"
bound_repo=$(cd "$bound_repo" && pwd -P)
cp \
  "$scratch/expected-event.jsonl" \
  "$bound_repo/.ledger/learnings/events.jsonl"
bound_digest_before=$(
  shasum -a 256 "$bound_repo/.ledger/learnings/events.jsonl" |
    awk '{print $1}'
)
"$ledger_bin" transact \
  --definition "$definition" \
  --operation bind-existing \
  --repo "$bound_repo" \
  --format json >"$scratch/bind.json"
jq -e \
  '.operation == "bind-existing" and
   .effects[0].result == "bound" and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  "$scratch/bind.json" >/dev/null
bound_digest_after=$(
  shasum -a 256 "$bound_repo/.ledger/learnings/events.jsonl" |
    awk '{print $1}'
)
[[ "$bound_digest_before" == "$bound_digest_after" ]]

recall_repo="$scratch/recall-repo"
mkdir -p "$recall_repo/.ledger/learnings"
recall_repo=$(cd "$recall_repo" && pwd -P)
jq -c -n \
  '
    def event($id; $captured_at; $learning; $paths; $tag; $supersedes):
      {
        v: 1,
        source: "learnings",
        event: "learning.capture",
        learning_id: $id,
        status: "do_more",
        record: ({
          id: $id,
          captured_at: $captured_at,
          status: "do_more",
          learning: $learning,
          evidence: ["proof"],
          application: "Apply the selected route.",
          context: {
            repo: "owner/repo",
            branch: "main",
            paths: $paths
          },
          source: "ledger:learnings",
          fingerprint: ($id | split("-")[-1] + "00000000"),
          tags: [$tag],
          related_ids: []
        } + if $supersedes == null then {} else {
          supersedes_id: $supersedes
        } end)
      };
    [
      ["lrn-20260701T000000Z-11111111", "2026-07-01T00:00:00Z", "Preserve the cache definition.", [], "retired", null],
      ["lrn-20260702T000000Z-22222222", "2026-07-02T00:00:00Z", "Preserve the cache definition.", [], "same", "lrn-20260701T000000Z-11111111"],
      ["lrn-20260703T000000Z-33333333", "2026-07-03T00:00:00Z", "Preserve the cache definition.", [], "same", null],
      ["lrn-20260704T000000Z-44444444", "2026-07-04T00:00:00Z", "Preserve the cache definition.", [], "same", null],
      ["lrn-20260705T000000Z-55555555", "2026-07-05T00:00:00Z", "Use a distinct route.", ["src/ledger.zig"], "other", null]
    ][]
    | event(.[0]; .[1]; .[2]; .[3]; .[4]; .[5])
  ' >"$recall_repo/.ledger/learnings/events.jsonl"
"$ledger_bin" transact \
  --definition "$definition" \
  --operation bind-existing \
  --repo "$recall_repo" \
  --format json >"$scratch/recall-bind.json"
jq -e \
  '.effects[0].result == "bound" and
   .semantic_authority_granted == false and
   .storage_mutated == true' \
  "$scratch/recall-bind.json" >/dev/null

"$ledger_bin" project \
  --definition "$definition" \
  --projection recent \
  --repo "$recall_repo" \
  --param "limit=3" \
  --payload-only \
  --format json >"$scratch/recent.json"
jq -e \
  'map(.id) == [
     "lrn-20260705T000000Z-55555555",
     "lrn-20260704T000000Z-44444444",
     "lrn-20260703T000000Z-33333333"
   ]' \
  "$scratch/recent.json" >/dev/null

"$ledger_bin" project \
  --definition "$definition" \
  --projection recall \
  --repo "$recall_repo" \
  --param "query=cache src/ledger.zig" \
  --param "now=2026-07-06T00:00:00Z" \
  --param "drop_superseded=true" \
  --param "search_limit=5" \
  --payload-only \
  --format json >"$scratch/recall.json"
jq -e \
  'map(.id) == [
     "lrn-20260705T000000Z-55555555",
     "lrn-20260704T000000Z-44444444",
     "lrn-20260703T000000Z-33333333"
   ] and
   all(.[]; (.score | type) == "number")' \
  "$scratch/recall.json" >/dev/null

if [[ -n ${BASE_LEDGER_BIN:-} ]]; then
  command -v "$BASE_LEDGER_BIN" >/dev/null
  comparison_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  (
    cd "$recall_repo"
    "$BASE_LEDGER_BIN" recall \
      --source learnings \
      --query "cache src/ledger.zig" \
      --limit 5 \
      --format json \
      --drop-superseded
  ) >"$scratch/base-recall.json"
  "$ledger_bin" project \
    --definition "$definition" \
    --projection recall \
    --repo "$recall_repo" \
    --param "query=cache src/ledger.zig" \
    --param "now=$comparison_now" \
    --param "drop_superseded=true" \
    --param "search_limit=5" \
    --payload-only \
    --format json >"$scratch/candidate-recall.json"
  jq -e \
    --slurpfile base "$scratch/base-recall.json" \
    '
      def absolute: if . < 0 then -. else . end;
      . as $candidate |
      ($candidate | length) == ($base[0] | length) and
      all(range(0; $candidate | length);
        . as $index |
        $candidate[$index].id == $base[0][$index].id and
        (($candidate[$index].score - $base[0][$index].score) | absolute) <
          0.00001
      )
    ' \
    "$scratch/candidate-recall.json" >/dev/null
fi

printf 'learnings protocol conformance passed: generated=1 invalid=1 bindings=2 transactions=2 projections=4 memory_validations=1\n'
