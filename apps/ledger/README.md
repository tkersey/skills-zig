# Ledger

Ledger 1.1 compiles passive artifact definitions into bounded native plans for
validation, canonicalization, identity, durable transactions, replay, and
projection.

```text
read bounded input
-> parse and canonicalize
-> validate
-> derive identity
-> admit declared storage effects
-> replay or project
-> emit a structural receipt
```

Ledger never executes definition data, inspects session history, or grants
semantic authority.

## Build and test

From the repository root:

```bash
zig build build-ledger -Doptimize=ReleaseFast
zig build test-ledger -Doptimize=ReleaseFast
zig build test-ledger-segmented -Doptimize=ReleaseFast
```

The binary is written to `zig-out/bin/ledger`.

## Definitions

Definitions use `ledger-artifact-definition/v1` and require
`ledger-artifact-abi/v1`.

```bash
ledger definition check \
  --definition <artifact-definition.json> \
  --format json

ledger definition describe \
  --definition <artifact-definition.json> \
  --format json
```

Definitions are passive JSON. They may declare bounded JSON, JSONL, and UTF-8
text inputs, imports under an admitted definition root, native structural
operators, identity, logical storage, transactions, reducers, and projections.
They cannot name hooks or executable code.

## Pure operations

```bash
ledger validate \
  --definition <artifact-definition.json> \
  --input artifact=<artifact.json> \
  --format json

ledger materialize \
  --definition <artifact-definition.json> \
  --input artifact=<artifact.json> \
  --format json
```

`validate` and `materialize` do not read or mutate a repository store.
Validation returns `ledger-validation-result/v1`; materialization returns
`ledger-materialization-result/v1`.

## Durable operations

```bash
ledger transact \
  --definition <protocol-definition.json> \
  --operation <operation> \
  --repo <repo> \
  --input event=<event.json> \
  --param id=<id> \
  --format json

ledger project \
  --definition <protocol-definition.json> \
  --projection <projection> \
  --repo <repo> \
  --param id=<id> \
  --format json

ledger doctor \
  --definition <protocol-definition.json> \
  --repo <repo> \
  --format json

ledger migrate-segmented \
  --definition <protocol-definition.json> \
  --repo <repo> \
  --format json
```

Segmented event-log slots use 64 MiB event segments, resumable checkpoints,
and an explicit atomic migration. Ordinary replay reads only the checkpoint and
active suffix; `doctor` walks every segment sequentially and verifies the full
event and binding history without imposing a lifetime-size ceiling.

Transactions write only declared logical slots under the selected repository's
`.ledger/` root. Definitions cannot select absolute output paths or escape the
control root. Current reads fail closed for unbound stores; an owning
definition may expose an explicit one-shot binding operation for an existing
validated store.

When an authoritative external transport such as Git replaces an already-bound
store with another complete valid revision, the owner may expose a separate
`rebind-existing` operation. It validates the complete current store, requires
an existing stale binding, atomically replaces only Ledger's binding metadata,
and leaves the store bytes unchanged. It rejects invalid stores, missing
bindings, and already-current bindings.

Use `ledger project --payload-only` only for explicit structural piping. Normal
JSON projections preserve the `ledger-projection-result/v1` envelope and its
definition/store identity.

## Recovery maintenance

Automatic recovery never treats lease expiry as an authority transfer. Inspect
one legacy transaction for an exact expired lease witness before authorizing
any repair:

```bash
ledger recovery inspect \
  --repo <repo> \
  --transaction <dtx-id> \
  --format json

ledger recovery reclaim \
  --repo <repo> \
  --transaction <dtx-id> \
  --resource <path> \
  --lock-id <dlk-id> \
  --fencing-token <u64> \
  --confirm-no-legacy-writers \
  --format json
```

`reclaim` accepts no broad mode. It revalidates the transaction, lock identity,
owner, resource, fencing token, and lease witness immediately before advancing
the fencing authority and preserving the retired lease as no-replace recovery
evidence. An interrupted current recovery is transaction-bound and can be
reclaimed once Ledger holds the transaction recovery lock. An original legacy
lease additionally requires `--confirm-no-legacy-writers`, an operator
assertion that no pre-advisory-lock writer can still refresh or release it.

## Native surface

```text
ledger definition check
ledger definition describe
ledger validate
ledger materialize
ledger transact
ledger project
ledger doctor
ledger recovery inspect
ledger recovery reclaim
ledger capabilities
ledger version
```

`ledger capabilities --format json` reports only artifact ABIs, native
operators, codecs, storage adapters, cache format, generic bounds, and result
schemas. Every result keeps structural claims distinct from semantic authority.

## Directed relations (Ledger 1.2)

Keyed reducers may declare one bounded directed relation over their retained
records. The definition chooses the discriminator, vertex/edge tags, endpoint
paths, active edge states, and whether the active relation must be acyclic:

```json
"relation": {
  "discriminator": "/type",
  "vertex_tag": "vertex",
  "edge_tag": "arc",
  "source": "/source",
  "target": "/target",
  "active_states": ["linked"],
  "acyclic": true,
  "max_vertices": 128,
  "max_edges": 1024
}
```

This is an optional field of the existing `reducer` law (operator version 6).
Vertices use their reducer keys as identity. Endpoint paths are relative to the
retained record. Every edge resolves to two vertices, and each ordered pair has
one retained identity, including inactive edges. Unknown roles, dangling
endpoints, duplicate pairs, and capacity violations fail closed. With `acyclic`
enabled, active self-edges and cycles are rejected. An inactive edge remains in
history but does not participate in cycle checks or target queries.

Admission checks the whole prospective relation before committing the keyed
transition. Replay and checkpoint validation enforce the same relation. Reuse
normal expected-revision and idempotency controls; a refreshed revision does not
bypass the relation law. No second store, persistent index, domain scheduler, or
external effect is introduced. The index is reconstructed from the selected
reducer state, using iterative O(vertices + edges) cycle checking.

A keyed `fold` (operator version 7) can select vertices or edges and optionally
match the states of outgoing targets:

```json
"relation": {
  "select": "vertices",
  "target_states": ["satisfied"],
  "match": "all",
  "unmatched_field": "missing_targets"
}
```

`match` is `any` (no target predicate), `all` (no unsatisfied outgoing targets),
or `not_all` (at least one unsatisfied target). A vertex without outgoing active
edges satisfies `all`. `unmatched_field` optionally returns exact, key-sorted
unsatisfied target IDs. Ordinary keyed-fold filters may select vertex lifecycle
states afterwards; reference resolution always uses the complete state, not the
filtered subset. `select: "edges"` supports the ordinary fold fields and state
filters, without target-state predicates.

Queries reject unknown state names, collisions with existing output fields,
undeclared relations, and unsupported compositions with keyed history or
constructed exports. Limits and byte bounds remain the normal projection
contract; native result envelopes bind results to the definition and revision.
No result is permission to execute, publish, or close a domain object.

See `src/v1/fixtures/relation-definition.json` and
`scripts/test-ledger-relations.sh` for a complete generic example. Existing
relation-free definitions retain their behavior. Cache payload versions are
advanced; stale caches rebuild through the normal source path. This feature
requires the Ledger 1.2 release before production consumers depend on it.
