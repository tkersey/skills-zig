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
ledger reopen --id NEG-000001
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

## Route Gate

`map` emits a machine-readable `negative_route_gate` object.

- Exact route or exact cluster matches can block only when the artifact is applicable.
- Fuzzy lexical matches are advisory only.
- A missing store fails closed with exit code `3` and `failure:"ledger_missing"`.
- An active exact exclusion exits `2`.
- No active exclusion exits `0`.

This keeps "no active exclusion" as data instead of prose.
