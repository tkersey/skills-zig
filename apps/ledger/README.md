# ledger

Repo-local durable negative evidence ledger.

`ledger` stores disconfirmed hypotheses, failed routes, reopening criteria, and route-exclusion evidence in an append-only JSONL file that future runs can query directly.

Default store:

```bash
.ledger/negative-ledger.jsonl
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
```

Use `--file PATH` to point at a non-default store.

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
    "store": ".ledger/negative-ledger.jsonl",
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
