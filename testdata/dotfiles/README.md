# Dotfiles definition conformance

This is test-only black-box data for validating the passive definitions shipped
by dotfiles against exact Seq and Ledger candidate binaries. It is not compiled
into either product and is not part of a deployed skill package.

Each `ledger-definition-conformance-cases/v4` suite lists canonical base IDs;
`bases/<id>.json` is both the source file and an implicit valid case. Only
additional `valid` variants and `invalid` counterexamples are catalogued.
Variants use JSON-Pointer `set`/`remove` deltas and may omit `base` when the
suite has one. `materializations` is keyed by case ID. One
`reconstructed_cases_digest` still binds every reconstructed case byte-for-byte.

Stateful protocol suites reuse those named cases and the same pointer-delta
encoding. Their catalog contains only source-case references, dynamic bindings,
one reconstructed-candidate-set digest, and expected transaction outcomes.
Shared setup is executed by the protocol runner; canonical Goal, Construction,
and Counterexample documents are never copied into protocol fixtures.

Run the exact-candidate gate with:

```bash
DOTFILES_ROOT=/path/to/dotfiles \
SEQ_BIN=/path/to/seq-v1-candidate \
LEDGER_BIN=/path/to/ledger-v1-candidate \
testdata/dotfiles/scripts/check-skill-definitions.sh
```
