# Ledger

Ledger 1.2 compiles passive artifact definitions into bounded native plans for
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

## Bounded relations on keyed reducers

Ledger 1.2 adds optional `relation` facets to `reducer` v6 and keyed `fold` v7.
They introduce no task-specific commands, workflow authority, arbitrary queries,
or executable hooks. Definitions without the facet retain their existing behavior.

A reducer with `retain_once` may declare this generic directed graph view over its
retained records (paths are relative to the retained value):

```json
{
  "discriminator": "/type",
  "vertex_value": "component",
  "edge_value": "relation",
  "source": "/from",
  "target": "/to",
  "active_states": ["present"],
  "max_vertices": 128,
  "max_edges": 1024,
  "acyclic": true
}
```

Every record is classified as a vertex or edge. Every edge resolves both endpoint
keys; active ordered pairs are unique. With `acyclic: true`, active self-edges and
cycles are rejected. Admission validates the prospective successor under existing
transaction custody before committing the keyed change. Replay, checkpoint
activation, and relation projection revalidate the graph. No independent graph
store or derived-state cache is introduced.

An optional relation query on a keyed fold selects `vertices` or active `edges`:

```json
{"select":"vertices","target_states":["satisfied"],"match":"all","unmatched_field":"unmatched"}
```

`match` is `any` (no relation filtering, the default), `all` (no unmatched direct
target), or `not-all` (at least one unmatched direct target). `unmatched_field`
adds sorted target keys not in `target_states`. Zero outgoing edges satisfies
`all`. An `edges` query cannot request target predicates. Existing keyed filters,
ID lookup, and limits compose with the relation fold; constructed exports and
keyed history annotations are explicitly rejected for this facet.

Vertices and edges share the reducer identity space. Definitions own unambiguous
identity construction, event shapes, legal lifecycle transitions, and interpretation
of states. Inactive edges still count toward identity bounds and must resolve their
endpoints. Runtime maxima are 4,096 vertices, 65,536 edges, 256 state labels, and
64 KiB per relation/query configuration; normal retained-byte and output bounds
also apply. Cycles are checked by an iterative bounded topological traversal.

The motivating integration is an owner-defined mutable work graph. The added
mechanism is a bounded relational interpretation of existing keyed state, not a
registry of task semantics or a general-purpose graph query language. Native
fixtures use component/relationship labels, and existing definitions require no
changes. The compiled cache payload changes to prevent reuse of older plans.

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
