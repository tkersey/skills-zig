# Dotfiles definition conformance

This is test-only black-box data for validating the passive definitions shipped
by dotfiles against exact Seq and Ledger candidate binaries. It is not compiled
into either product and is not part of a deployed skill package.

Each artifact has one root witness. Named valid variants and invalid
counterexamples form an acyclic `from` graph of JSON-Pointer `set`/`remove`
deltas. The harness reconstructs and validates every node, so the catalog does
not repeat full documents, verdict fields, or self-authored checksums.

Stateful protocol suites reuse those named cases and the same pointer-delta
encoding. Their catalog contains only source-case references, dynamic bindings,
one reconstructed-candidate-set digest, and expected transaction outcomes.
Shared setup is executed by the protocol runner; canonical Goal, Construction,
and Counterexample documents are never copied into protocol fixtures.

Run the exact-candidate gate with:

```bash
DOTFILES_ROOT=/path/to/dotfiles \
SEQ_BIN=/path/to/seq \
LEDGER_BIN=/path/to/ledger \
testdata/dotfiles/scripts/check-skill-definitions.sh
```
