# ledger

Repo-local durable source-memory ledger.

`ledger` stores disconfirmed hypotheses, failed routes, reopening criteria, and route-exclusion evidence in an append-only JSONL file that future runs can query directly.
It also owns learning capture under `--source learnings`.

Default store:

```bash
.ledger/negative-ledger/events.jsonl
```

Learning source store:

```bash
.ledger/learnings/events.jsonl
```

## Commands

```bash
ledger init
ledger capture --json capture.json
ledger query
ledger map --route review-route --cluster same-cluster --artifact HEAD
ledger show --id NEG-000001
ledger status --id NEG-000001 --to stale --reason "artifact state changed"
ledger reopen --id NEG-000001
ledger export --id NEG-000001 --format full
ledger export --id NEG-000001 --format memory-note
ledger handoff
ledger compact
ledger doctor
ledger migrate --mode copy
ledger capture --source learnings --learning "When X, prefer Y because Z." --evidence "command/result" --application "Do Y next time."
ledger recall --source learnings --query "focused task" --limit 5 --drop-superseded
ledger migrate --source learnings --mode copy
ledger doctor --source learnings
```

Use `--file PATH` to point at a non-default store.
For `--source learnings`, `--file PATH` is accepted as an alias for the learning event path.

Path migration:

```bash
ledger migrate \
  --from .ledger/negative-ledger.jsonl \
  --to .ledger/negative-ledger/events.jsonl \
  --mode copy
```

Learning path migration:

```bash
ledger migrate --source learnings --mode copy
```

This converts legacy rows from `.ledger/learnings/learnings.jsonl` or `.learnings.jsonl` into event envelopes:

```json
{"v":1,"source":"learnings","event":"learning.capture","learning_id":"lrn-...","status":"do_more","record":{ "...": "old learning row fields" }}
```

## Capture

`capture` accepts JSON from a file or stdin:

```json
{
  "hypothesis": "route fails under current artifact",
  "route_id": "review-route",
  "cluster_id": "same-cluster",
  "artifact_state_id": "HEAD",
  "source_refs": [
    { "kind": "test", "ref": "zig build test-ledger --summary all" }
  ]
}
```

Records get monotonic `NEG-*` ids. A capture that requests `active` without witness evidence is stored as `need-evidence`, not as an active exclusion.

For learning capture, use `--source learnings` with the learning flags:

```bash
ledger capture --source learnings \
  --status do_more \
  --learning "When a documented CLI form has already propagated, keep a tested compatibility alias because agents copy command forms." \
  --evidence "zig build test-ledger passed after adding parser coverage" \
  --application "Add compatibility before only updating docs." \
  --tag cli
```

Use `--record-source SOURCE` to override the source marker stored inside the learning row.

Active exclusions are route-scoped by default. Same-cluster recurrence is reusable memory, not an automatic ban.

To block a whole cluster, the capture must explicitly use `exclusion_scope:"cluster"` and include a non-empty `exclusion_rule`:

```json
{
  "hypothesis": "cluster route family is falsified",
  "cluster_id": "same-cluster",
  "exclusion_scope": "cluster",
  "exclusion_rule": "do not repeat this route family until reopened",
  "source_refs": [
    { "kind": "cas-review", "ref": "RGR-v2 wave 3" }
  ]
}
```

## Route Gate

`map` emits a machine-readable `negative_route_gate` object.

- Exact route matches can block when active, witnessed, and artifact-applicable.
- Exact cluster matches can block only when the record is explicitly cluster-scoped with an `exclusion_rule`.
- Fuzzy lexical matches are advisory only.
- A missing store fails closed with exit code `3` and `failure:"ledger_missing"`.
- Invalid gate input or invalid store content fails closed with exit code `3`.
- An active exact exclusion exits `2`.
- No active exclusion exits `0`.

This keeps "no active exclusion" as data instead of prose.

Example shape:

```json
{
  "negative_route_gate": {
    "checked": true,
    "query_or_map": "yes",
    "ledger_cli": "ledger",
    "store": ".ledger/negative-ledger/events.jsonl",
    "command": "ledger map --route review-route --cluster same-cluster --artifact HEAD",
    "exit_code": 0,
    "ledger_available": true,
    "active_exclusion_match": false,
    "exclusion_id": "none",
    "fuzzy_candidates": 0,
    "fuzzy_authority": "suggest_only",
    "failure": "none",
    "handoff_allowed": true
  }
}
```

`doctor` validates both JSONL integrity and projection safety, including malformed events and active records that cannot legally block.

## Lifecycle and memory projection

`status` appends lifecycle events without rewriting historical captures:

```bash
ledger status \
  --id NEG-000001 \
  --to reopened \
  --reason "The old benchmark fixture was replaced."
```

Supported projected statuses are `capture_candidate`, `need-evidence`, `unknown`, `active`, `accepted_risk`, `stale`, `reopened`, and `superseded`. Only `active` records can block route selection.

Use `export` for complete current projections:

```bash
ledger export --id NEG-000001 --format full
ledger export --id NEG-000001 --format memory-note |
  memory-note append --extension negative-ledger --kind ledger-projection --json -
```

`show` remains concise and now includes `source_event_count` and `projection_fingerprint`; memory admission should use `export --format memory-note`.
