# resolve-c3

Zig controller for the `$resolve` C3 workflow.

This app owns the runtime command surface that will replace the legacy Python controller and gate scripts. Runtime state belongs under `.ledger/c3/`; legacy `.resolve-c3/` state is handled only by the explicit migration command added in the lifecycle implementation wave.

## Capabilities

`resolve-c3 capabilities --json` reports the MBKC-v1 controller surface:

- state v2 is writable; state v1 remains readable for migration.
- MBKC-v1 is writable; MRPC-v1 remains readable for legacy gates.
- campaign-base, minimum-behavioral-kernel, semantic-surface, proof-compression, physical-delivery, closure-horizon, and Zig adapter feature flags are advertised for the 0.2.x implementation line.

## Commands

- `resolve-c3 capabilities --json`: print machine-readable controller capabilities.
- `resolve-c3 schema <artifact> --json`: print the strict schema projection for an artifact.
- `resolve-c3 example <artifact|command> --json`: print a JSON example for an artifact or command.
- `resolve-c3 init`: create `.ledger/c3/` state and install the local exclude guard.
- `resolve-c3 doctor`: print current controller path defaults.
- `resolve-c3 paths`: print the active state and legacy roots.
- `resolve-c3 status`: report whether `.ledger/c3/state.json` exists.
- `resolve-c3 campaign begin|status|audit|rebaseline|abort`: create, inspect, audit, explicitly rebaseline, or abort a campaign.
- `resolve-c3 observation add|import|list|classify`: ingest and inspect accepted review observations.
- `resolve-c3 kernel set|lint|minimize|review|accept`: store and gate the Minimum Behavioral Kernel.
- `resolve-c3 design register|select|list`: register and select code-free realization designs.
- `resolve-c3 realization worktree|capture|measure|map|verify|minimize`: create a base-pinned realization worktree, derive patch/tree/surface artifacts, validate construct maps, verify conformance, and emit local minimization receipts.
- `resolve-c3 proof plan|run|compress`: generate law coverage, execute proof commands with tree-stability checks, and write a compressed proof basis.
- `resolve-c3 delivery apply|commit|push`: replace the delivery tree from the captured realization tree, create an actual Git commit, and push the branch.
- `resolve-c3 certify tuple|terminal`: record tuple-bound or terminal closure after physical delivery.
- `resolve-c3 migrate mrpc --from <state-root> --campaign-base <sha> --review-ready-baseline <sha>`: archive MRPC/v1 artifacts and create a v2 initialized campaign without accepting a kernel.

Schema/example artifacts:

```text
acceptance
observation
kernel
kernel-review
realization-design
construct-map
proof-plan
holdout
mbkc
```

## State

New controller state is rooted at `.ledger/c3/` and starts with:

```text
state.json
events.jsonl
mbkc.json
realization/manifest.json
realization/patch.bin
realization/tree.txt
realization/construct-map.json
realization/surface.json
proof/plan.json
proof/results.jsonl
proof/basis.json
```

`state.json` is emitted as `resolve-c3-state-v2`. `mbkc.json` is a generated MBKC-v1 projection foundation. Realization capture derives patch, tree, construct, and surface artifacts from the controller-created worktree. Proof run fingerprints the realization tree before and after commands and fails if the proof mutates the tree. Delivery apply creates a backup ref and uses Git tree replacement from the captured realization tree; delivery commit and push run real Git operations. Tuple and terminal closure are separate MBKC stages.

## Migration

`resolve-c3 migrate mrpc` archives known v1/MRPC artifacts under `.ledger/c3/archive/mrpc/`, writes `migration-receipt.json`, and creates fresh state v2 in `initialized` phase. The migration receipt records `kernel_accepted:false`; a fresh kernel review is required before any new delivery mutation.

## Workflow Boundary

The 0.2.x workflow separates kernel review from implementation conformance:

1. Review evidence is ingested as observations.
2. Observations refine one campaign-wide Minimum Behavioral Kernel.
3. A selected realization design maps that kernel to code owners and surfaces.
4. The controller captures and verifies the whole-PR realization from the fixed campaign base.
5. Delivery apply, commit, push, tuple closure, and terminal closure are controller-gated physical operations.

## Build

```sh
zig build build-resolve-c3
zig build test-resolve-c3
zig build run-resolve-c3
```
