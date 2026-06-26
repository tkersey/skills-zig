# Open Questions: `$st` Operational Graph Gates

These questions should be resolved before the implementation PR changes runtime
behavior.

1. Should `proof_cut_kind=approximation` ever allow `execution_allowed=yes` for
   material mutation, or should only `exact` permit mutation?
2. Should `st graph receipt` persist receipts by default or only print them?
3. Should GRR-v1 be emitted automatically on every failing command, or only when
   `--format json` or `--emit-repair-receipt` is supplied?
4. Should AMR-v1 live under `.ledger/st/maintenance/` or under the migration
   directory when it concerns legacy sidecars?
5. Should `seq` consume AMR-v1 before or after the review-compiler classifier's
   true-workflow detector?
6. What is the minimal graph-intelligence subset required for legacy single-plan
   compatibility?

Default recommendations:

- Permit material mutation with `exact` proof cut only at first.
- Let read-only receipt commands print by default and persist only with
  `--write-receipt`.
- Emit GRR-v1 automatically for JSON-formatted failures.
- Store AMR-v1 under `.ledger/st/maintenance/` with references into migration
  receipts when applicable.
- Teach `seq` provenance classification before review-compiler aggregation.
- Keep legacy compatibility read-only unless workspace mode is active.
