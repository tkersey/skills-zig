# resolve-c3

Zig controller for the `$resolve` C3 workflow.

This app owns the runtime command surface that will replace the legacy Python controller and gate scripts. Runtime state belongs under `.ledger/c3/`; legacy `.resolve-c3/` state is handled only by the explicit migration command added in the lifecycle implementation wave.

## Capabilities

`resolve-c3 capabilities --json` reports the intent-closed CEGIS controller foundation:

- `intent_closed_cegis_v1`, MBKC-v1, and MRPC-v1 read compatibility are advertised.
- state v3 is writable; state v1 and v2 remain readable for migration and audits.
- MBKC-v1 is writable; MRPC-v1 remains readable for legacy gates.
- AC-v2, sealed review horizons, review batches/apertures, CEX-v1, CEB-v2, MBK/RC, PHI-v1, targeted conformance, terminal holdout, semantic surface, proof compression, RAC-v1 authority-chain, mutation gate, closure gate, physical delivery, closure horizon, and mutation-guard-v2 feature flags are advertised for the 0.3.x implementation line.

## Commands

- `resolve-c3 capabilities --json`: print machine-readable controller capabilities.
- `resolve-c3 schema <artifact> --json`: print the strict schema projection for an artifact.
- `resolve-c3 example <artifact|command> --json`: print a JSON example for an artifact or command.
- `resolve-c3 init`: create `.ledger/c3/` state and install the local exclude guard.
- `resolve-c3 doctor`: print current controller path defaults.
- `resolve-c3 paths`: print the active state and legacy roots.
- `resolve-c3 status`: report whether `.ledger/c3/state.json` exists.
- `resolve-c3 campaign begin|status|audit|rebaseline|abort`: create, inspect, audit, explicitly rebaseline, or abort a campaign.
- `resolve-c3 acceptance set|validate|seal|status|rebase`: store, validate, seal, inspect, or explicitly invalidate/rebase an AC-v2 package.
- `resolve-c3 review batch begin|status|seal|invalidate`: manage one sealed review horizon with an open-batch mutation barrier.
- `resolve-c3 review aperture add` / `resolve-c3 review receipt add`: store typed RAP-v1 apertures and terminal review receipts for a batch.
- `resolve-c3 review plan|plan status`: validate and store supplied aperture plans without executing CAS.
- `resolve-c3 counterexample add|classify|list|show`: admit and inspect CEX-v1 records with controller-derived `mutation_authority:false`.
- `resolve-c3 basis compile|lint|seal|status`: validate and seal a CEB-v2 quotient from accepted in-horizon CEX records in sealed review batches.
- `resolve-c3 observation add|import|list|classify`: ingest and inspect accepted review observations.
- `resolve-c3 kernel set|lint|minimize|review|accept`: store and gate the Minimum Behavioral Kernel.
- `resolve-c3 reduction set|lint|review|accept`: store and accept RC-v1 reduction certificates bound to the current AC/CEB fingerprints.
- `resolve-c3 design register|select|list`: register and select code-free realization designs; selected designs must bind the current AC, CEB, and accepted kernel fingerprints.
- `resolve-c3 realization worktree|capture|measure|map|verify|minimize`: create a base-pinned realization worktree, derive patch/tree/surface artifacts, validate construct maps, require sealed targeted conformance, and emit local minimization receipts.
- `resolve-c3 potential baseline|measure|gate|status`: store PHI-v1 metric evidence and certify controller-derived strict semantic progress.
- `resolve-c3 proof plan|run|compress`: generate intent/class-mapped law coverage, execute proof commands with tree-stability checks, and write a compressed proof basis.
- `resolve-c3 delivery apply|commit|push`: after sealed clean conformance, PHI strict progress, current proof basis, and current fingerprints, replace the delivery tree from the captured realization tree, create an actual Git commit, and push the branch.
- `resolve-c3 certify tuple|terminal`: record tuple-bound closure from a clean PR sweep receipt, then terminal closure only after a sealed clean terminal holdout and explicit reopen conditions.
- `resolve-c3 authority-chain init|check`: native RAC-v1 command surface for review-originated mutation authority chains.
- `resolve-c3 mutation-gate`: fail-closed RAC-v1 gate that permits review-originated mutation only after the compiled authority chain is complete, current, and mutation-authorizing.
- `resolve-c3 closure-gate --campaign <id> --summary <summary.json> --runs <runs.jsonl> --format text|json`: fail-closed material delivery gate for seq summary/runs artifacts. It blocks delivery closure language when C3 is unentered or unsealed, compression/proof/kernel authority is missing, terminal holdout is absent, strict progress is zero, construct/proof mappings are unmapped, or semantic surface growth lacks an explicit AC rebase.
- `resolve-c3 migrate mrpc --from <state-root> --campaign-base <sha> --review-ready-baseline <sha>`: archive MRPC/v1 artifacts and create an initialized campaign without accepting a kernel.
- `resolve-c3 migrate intent-closed --from <state-root> --acceptance <acceptance-v2.json> --campaign-base <sha> --review-ready-baseline <sha> --confirm`: archive legacy artifacts and start a v3 intent-open campaign with a draft AC-v2, requiring fresh discovery/basis/kernel gates before mutation.

Schema/example artifacts:

```text
acceptance
acceptance-v2
observation
review-batch
review-aperture
counterexample
counterexample-basis-v2
review-potential
kernel
kernel-review
realization-design
construct-map
proof-plan
holdout
authority-chain
mbkc
```

## State

New controller state is rooted at `.ledger/c3/` and starts with:

```text
state.json
events.jsonl
acceptance.json
acceptance-history/
review/batches/
review/apertures/
review/receipts/
counterexamples.jsonl
basis.json
kernel.json
kernel-review.json
reduction-certificate.json
designs.jsonl
selected-design.json
potential/baseline.json
potential/cycles.jsonl
potential/current.json
mbkc.json
realization/manifest.json
realization/patch.bin
realization/tree.txt
realization/construct-map.json
realization/surface.json
realization/worktree-receipt.json
proof/plan.json
proof/results.jsonl
proof/basis.json
holdout/batch.json
holdout/receipts/
delivery/apply-receipt.json
delivery/commit-receipt.json
delivery/push-receipt.json
migration/
archive/
```

`state.json` is emitted as `resolve-c3-state-v3` for new material campaigns with `protocol_profile:"intent-closed-cegis-v1"`. The v3 projection includes campaign, acceptance, review, counterexample, basis, kernel, reduction, design, realization, potential, delivery, and closure sections while retaining legacy compatibility fields during the incremental rollout. `mbkc.json` is a generated MBKC-v1 projection foundation. Realization capture derives patch, tree, construct, and surface artifacts from the controller-created worktree. Proof run fingerprints the realization tree before and after commands and fails if the proof mutates the tree. Delivery apply creates a backup ref and uses Git tree replacement from the captured realization tree; delivery commit and push run real Git operations. Tuple and terminal closure are separate MBKC stages.

## Migration

`resolve-c3 migrate mrpc` archives known v1/MRPC artifacts under `.ledger/c3/archive/mrpc/`, writes `migration-receipt.json`, and creates fresh initialized state without accepting a kernel. The migration receipt records `kernel_accepted:false`; a fresh kernel review is required before any new delivery mutation.

`resolve-c3 migrate intent-closed` archives legacy artifacts under `.ledger/c3/archive/intent-closed/`, writes a migration receipt with `accepted_legacy_artifacts:false`, and creates `resolve-c3-state-v3` in `intent_open` with the supplied AC-v2 as an unsealed draft. Legacy acceptance, CEB, kernel, and delivery artifacts are history only until the new gates pass.

## Workflow Boundary

The 0.3.x foundation preserves the existing MBKC workflow while adding the state surface needed for intent-closed CEGIS:

1. Review evidence is ingested as observations.
2. Observations refine one campaign-wide Minimum Behavioral Kernel.
3. A selected realization design maps that kernel to code owners and surfaces.
4. The controller captures the whole-PR realization from the fixed campaign base, then requires targeted conformance and strict PHI-v1 progress.
5. Delivery apply, commit, push, tuple closure, and terminal closure are controller-gated physical operations.

## Build

```sh
zig build build-resolve-c3
zig build test-resolve-c3
zig build run-resolve-c3
```
