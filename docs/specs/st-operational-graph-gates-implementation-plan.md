# Implementation Plan: `$st` Operational Graph Gates

This plan stages the implementation of `ST-OPERATIONAL-GRAPH-GATES-v1` after the
spec landed.

## Phase 1 — read-only receipts

- Add `st graph receipt`.
- Emit graph intelligence in JSON without changing execution behavior.
- Add fixtures for simple chain, diamond, disconnected components, and
  cross-plan blockers.
- Add capability flag `graph_intelligence_receipt_v1` only after tests pass.

## Phase 2 — GCR-v2 enforcement

- Embed graph-intelligence fields in `st compile aperture` when workspace,
  plan, session, and claim scope are present.
- Mark partial receipts `ledger_only`.
- Deny `execution_allowed` when proof cut or selection rationale is unavailable.

## Phase 3 — graph repair receipts

- Add GRR-v1 emission for intake, graph audit, and aperture compile failures.
- Persist receipts under `.ledger/st/plans/<plan-id>/repair/` in workspace mode.
- Add legacy read-only repair output for `.step/st-plan.jsonl` compatibility.

## Phase 4 — artifact maintenance receipts

- Add `st artifact-maintenance record`.
- Emit AMR-v1 for migration/sidecar repair flows.
- Teach `seq` to consume AMR-v1 before it is used in classifier gates.

## Phase 5 — strict mode and release

- Make material workspace mutation require graph-intelligence-complete GCR-v2.
- Update README examples.
- Bump `apps/st/VERSION` only with the implementation PR.
- Run:

```bash
zig build test-st
zig build build-st -Doptimize=ReleaseFast
```

## Exit criteria

The implementation is done when:

```text
selected task IDs alone cannot authorize material mutation
all graph failures produce GRR-v1 or structured denial
artifact-under-repair evidence cannot be confused with workflow activation
seq can audit the new receipts
```
