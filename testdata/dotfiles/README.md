# Dotfiles definition conformance

This is test-only black-box data for validating the passive definitions shipped
by dotfiles against exact Seq and Ledger candidate binaries. It is not compiled
into either product and is not part of a deployed skill package.

Each single-input artifact suite uses
`ledger-definition-conformance-cases/v1`:

- `bases` keeps one canonical compact document per genuinely distinct valid
  structural family.
- `cases` names the base, expected verdict, and optional ordered JSON Patch
  `add`, `remove`, or `replace` operations. JSON Pointer edits address nested
  objects and array members directly, so a one-field variant does not copy its
  enclosing container.
- `fixture_digest` binds each reconstructed case to the SHA-256 of its
  key-sorted compact JSON plus one trailing newline.
- `materialization` retains the expected artifact ID and canonical-content
  digest; `oracle`, when present, binds those values to the frozen base binary.
  The harness reconstructs and compares the complete canonical output, so
  expected files do not duplicate it.

Stateful protocol suites reuse those same named cases. Their scenario catalog
contains only source-case references, dynamic bindings, ordered JSON Pointer
deltas, reconstructed-candidate digests, and expected transaction outcomes.
Shared setup is executed by the protocol runner; canonical Goal, Construction,
and Counterexample documents are never copied into protocol fixtures.

Run the exact-candidate gate with:

```bash
DOTFILES_ROOT=/path/to/dotfiles \
SEQ_BIN=/path/to/seq-v1-candidate \
LEDGER_BIN=/path/to/ledger-v1-candidate \
testdata/dotfiles/scripts/check-skill-definitions.sh
```

The Actuating Evidence protocol proof is:

```bash
DOTFILES_ROOT=/path/to/dotfiles \
LEDGER_BIN=/path/to/ledger-v1-candidate \
testdata/dotfiles/scripts/check-actuating-evidence-protocol.sh
```
