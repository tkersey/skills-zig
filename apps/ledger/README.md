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
zig build build-ledger -Doptimize=fast
zig build test-ledger -Doptimize=fast
zig build test-ledger-segmented -Doptimize=fast
```

The binary is written to `zig-out/bin/ledger`.

## Canonical owner access and retained custody (Ledger 1.8)

Use the owner definition and migration declaration when selecting a history:

```bash
ledger context --catalog-root <catalog> --workspace <workspace> \
  --definition <definition.json> --owner-manifest <migration.json> --read-only
```

This verifies the selected canonical owner, its binding, replay and unresolved
publication state. A healthy present owner remains readable when an unrelated
sibling checkout is missing, empty or divergent. The returned `owner_health`
identifies the validated revision; `source_coverage: "not_checked"` explicitly
leaves migration coverage unknown. Read selection creates no history, catalog
association or writer authority. Before a semantic write, `--ensure-owner` admits
the same healthy selected owner without rescanning sibling worktrees. Workspace
and direct store-ID selectors have the same requirements for a present owner. Native
transactions still enforce binding, integrity, and writer exclusion; semantic
capture remains the caller's decision.
Ensure waits for selected-owner lock contention and recovers supported interrupted
native target transactions before reinspecting the owner. These conditions do
not trigger sibling discovery. Read-only selection does not perform recovery,
and malformed or unknown recovery state remains a failure.

Use `--reconcile-owner` with the same owner inputs and a selected workspace when
the intended operation needs source-family coverage. Successful reconciliation
or missing-owner preparation with a workspace reports `source_coverage: "checked"`
for that observed family. Healthy selected-owner access and archive-only repair
report `"not_checked"`. Missing worktrees, divergent histories, and uncoordinated actual
history remain reconciliation failures. A valid selected snapshot cannot prove
absence across unknown history or decide an unseen lifecycle transition.

For a missing owner, ensure discovers and prepares the selected source history.
If the selected ID has cataloged workspace associations, supply the workspace
whose source family must be checked. Store-ID-only ensure returns
`OwnerPreparationRequiresWorkspace` instead of treating uninspected associated
history as empty. Explicitly initialized isolated custody with no associations
remains usable by ID and reports `source_coverage: "not_checked"`.
Accessible empty sources establish native event/binding advisory coordination
and hold shared custody before accepting absence. They no longer require a
quiescence assertion merely because no writer has created a sidecar. Source
payloads remain unchanged; newly created coordination resources are reported by
`source_coordination_mutated`, also included in `storage_mutated`. Existing
nonempty history without qualified coordination still requires actual quiescence.
These guards exclude participating native writers, not unsupported writers that
ignore them. A retained pending identity survives interrupted preparation.

Discovery errors include `source_failure.source_root` and `error_code` when the
failing worktree is known. Unknown missing history remains unknown; ensure never
prunes the worktree or substitutes empty history.

An absent unbound owner returns `OwnerPreparationRequired`. Missing bytes with a
surviving binding return `StoreBindingWithoutSlot`, preserving the verified store
ID and root for exact recovery. Other corruption and identity failures keep their
specific errors. They are not empty-history observations. See
[preparation and exact restoration](PREPARATION.md) for archive recovery and the
atomic `--restore-bound-history` guard.

`ledger context --catalog-root <catalog> --list-stores` includes a separate
`pending` array for retained unpublished registrations. Each entry contains the
original registration and its `allocated` or `materialized` state, after validating
the locator placement, store identity and any materialized root marker. This
inventory is read-only and does not assert owner health. Equivalent separator
spellings and verified aliases of the same catalog home preserve retained placement
without rewriting the registration. An allocated identity remains discoverable
before its root exists. Cataloged IDs are omitted from `pending`; published
inventory remains available when custody is missing. This filtering does not
certify agreement between catalog and retained roots or relax preparation checks.

Preparation admits new control directories under the catalog lock before creating
them. At the discovery limit, a rejected allocation leaves existing retained IDs
readable. Retries reuse an existing directory, including an empty reservation left
by an interrupted attempt.

A materialized pending history can be inspected with the original ID, even after
the original checkout disappears:

```bash
ledger context --catalog-root <catalog> --store-id <retained-id> \
  --definition <definition.json> --owner-manifest <migration.json> --read-only
```

For an unpublished identity, success returns `cataloged: false`. This field reports
ID/root membership in the selected catalog, independently of workspace associations
and owner health. Equivalent checked root spellings retain the same membership
without changing recovery paths. If publication becomes visible before a durability
failure, the blocked response retains `cataloged: true` and the original error.
Reading does not publish the identity or permit write preparation.
Investigate the original failure and owner health before
using existing explicit `context --register-root <retained-root> --store-id
<retained-id>` to publish that exact identity. Registration is identity maintenance,
not certification of source coverage or writer cutover. Never allocate a replacement
ID, remove retained controls or treat a failed projection as an empty history.
Semantic repository scopes stored in owner records remain independent of custody
IDs and must be supplied unchanged to projections.

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

Event materialization verifies that derived values survive replay before it
commits an event. Replay can recover a canonically ordered source when the
declared event layout erased that ordering, but every derived value must match
the same reconstructed input and the stored layout must remain unchanged.
This preserves existing event bytes and identities under their archived
definitions.

Use `canonical_input` derivation fragments for identities that should be
independent of JSON object field order. `input_json` preserves source
serialization choices; a materialization that loses an unreconstructible
choice fails before appending an event.

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

## Ranked current state (Ledger 1.5)

A keyed `fold` can compose with filters, relevance, sort, structured-field export,
and limits. Ranking sees one current row per identity after lifecycle replay.
The `record-order` sort key uses the identity's first event position; later
updates do not move that position. Equal explicit sort keys also retain this
source order. Unsorted folds keep their canonical key order.

Sorted keyed folds reconstruct positions from validated history, including sealed
segments. They therefore read full history even when a checkpoint can supply the
current reducer state. Existing checkpoint bytes and migration formats are unchanged.

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
Following filters observe the emitted row, including its unmatched-target field.

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
