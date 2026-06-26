# PR Tracker: `$st` Operational Graph Gates

This tracker exists so the specification work has a PR-scoped review artifact.

## Landed spec files

- `docs/specs/st-operational-graph-gates.md`
- `docs/specs/seq-st-operational-evidence-audit.md`
- `docs/specs/st-operational-graph-gates-implementation-plan.md`
- `docs/specs/st-operational-graph-gates-open-questions.md`
- `docs/specs/README.md`

## Review checklist

- [ ] Confirm GCR-v2 graph-intelligence fields are sufficient for `$st` skill v2.1.
- [ ] Decide whether approximate proof cuts can authorize material mutation.
- [ ] Decide default persistence behavior for read-only receipts.
- [ ] Confirm AMR-v1 storage location.
- [ ] Split implementation into `st`, `durable_store`, and `seq` follow-up PRs.

## Follow-up PRs

1. `apps/st`: graph receipt and GCR-v2 enforcement.
2. `apps/st`: GRR-v1 and AMR-v1 commands.
3. `apps/seq`: provenance/evidence audit support.
4. `libs/durable_store`: only if additional transaction/fencing behavior is
   needed beyond the current APIs.
