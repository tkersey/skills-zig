# Ledger

Ledger 1.0 compiles passive artifact definitions into bounded native plans for
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
```

Transactions write only declared logical slots under the selected repository's
`.ledger/` root. Definitions cannot select absolute output paths or escape the
control root. Current reads fail closed for unbound stores; an owning
definition may expose an explicit one-shot binding operation for an existing
validated store.

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
  --lock-id <dlk-id> \
  --fencing-token <u64> \
  --format json
```

`reclaim` accepts no broad mode. It revalidates the transaction, lock identity,
owner, resource, fencing token, and expiry immediately before advancing the
fencing authority and preserving the retired lease as recovery evidence.

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
