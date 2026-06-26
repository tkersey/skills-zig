# SPEC: `$st` Operational Graph-Control Gates

Spec ID: `ST-OPERATIONAL-GRAPH-GATES-v1`  
Target repository: `tkersey/skills-zig`  
Target app: `apps/st`  
Current observed app version: `0.5.1`  
Primary skill contract: `codex/skills/st` v2.1

## 1. Executive directive

Upgrade `$st`'s workspace-era execution authority from "selected task IDs plus
claim/fencing" to a graph-intelligence-complete control receipt.

The current multi-plan workspace surface already introduces `.ledger/st`, plan
namespaces, workspace claims, sessions, worktrees, change sets, integration,
and GCR-v2 authority receipts. It still needs the operational gates introduced
by the skill contract:

```text
GCR-v2 graph intelligence
GRR-v1 graph repair receipts
AMR-v1 artifact maintenance provenance
capability/legacy-mode truthfulness
```

Material mutation must fail closed unless graph control is complete.

## 2. Goals

1. Extend GCR-v2 with graph intelligence.
2. Separate `ready_frontier`, `selected_frontier`, and `unselected_ready`.
3. Emit critical-path, fanout, component, and parallel-width facts.
4. Emit proof-cut facts or deny execution when no proof cut is available.
5. Explain aperture selection and non-selection.
6. Add graph repair receipts for failed intake/audit/aperture compilation.
7. Add artifact-maintenance receipts for sidecar/migration work.
8. Add capabilities for the new receipts.
9. Keep legacy single-plan compatibility honest.
10. Preserve existing workspace, claim, session, change-set, and integration behavior.
11. Provide `seq`-ready evidence rows.

## 3. Non-goals

1. Do not remove existing GCR-v1 output where compatibility still requires it.
2. Do not replace plan-local graph audit.
3. Do not treat graph analytics as a scheduler override by themselves.
4. Do not infer workflow activation from artifact path names.
5. Do not let agents hand-author these receipts as current authority.
6. Do not hold workspace locks during proof or Git execution.

## 4. Capabilities

Extend `st capabilities --format json`:

```yaml
st_capabilities:
  control:
    gcr_v2: true
    graph_intelligence_receipt_v1: true
    graph_repair_receipt_v1: true
    st_artifact_maintenance_receipt_v1: true
    ledger_mode_v1: true
  graph:
    critical_path_v1: true
    parallel_width_v1: true
    proof_cut_v1: true
    selected_vs_unselected_frontier_v1: true
```

If a capability is absent, agents must treat the installed CLI as analysis-only
for that feature. The CLI must not emit a partial receipt that looks complete.

## 5. GCR-v2 extension

Current README text says workspace-scoped aperture compilation emits legacy
GCR-v1 plus GCR-v2, and that GCR-v2 binds workspace sequence, plan sequence,
graph fingerprints, branch epoch, claim, fencing, resources, view digest,
selected task IDs, and `execution_allowed`.

Extend the receipt to:

```yaml
graph_control_receipt:
  receipt_version: GCR-v2
  gcr_id:

  workspace:
    workspace_id:
    workspace_sequence:
    target_branch:
    branch_epoch:
    head:
    working_tree_fingerprint:

  plan:
    plan_id:
    plan_sequence:
    graph_fingerprints:
      structure:
      contract:
      coverage:
      execution:

  coordination:
    claim_id:
    fencing_token:
    session_id:
    executor:
    resources: []
    conflicting_claims: []
    lease_current:
    fencing_current:

  graph:
    nodes:
    edges:
    roots: []
    leaves: []
    components:
      - component_id:
        node_ids: []
    ready_frontier: []
    blocked_frontier: []
    selected_frontier: []
    unselected_ready: []
    critical_path: []
    downstream_unlocks:
      - node_id:
        unlock_count:
        unlock_refs: []
    parallel_width:
    antichain_candidates: []
    high_fanout_nodes: []
    articulation_nodes: []
    graph_debt: []
    gate:
    gate_passed:

  proof:
    obligations: []
    missing: []
    minimum_proof_cut: []
    proof_cut_kind:
      exact |
      approximation |
      unavailable
    approximation_reason:

  aperture_decision:
    selected_nodes: []
    why_selected: []
    why_not_parallelized: []
    why_unselected_ready_waits: []
    fairness_state:
    scheduler_version:

  session_projection:
    view_id:
    session_id:
    selected_task_ids: []
    projection_digest:

  execution_allowed:
  denial_reasons: []
```

## 6. Execution gating

`execution_allowed=yes` requires all current v2 conditions plus:

```text
selected_frontier nonempty
selected_frontier subset of ready_frontier
ready_frontier = selected_frontier + unselected_ready, modulo deterministic ordering
blocked_frontier explained
critical_path present
parallel_width present
proof_cut_kind != unavailable
minimum_proof_cut nonempty unless no proof is required for read-only preview
every selected node has proof obligation coverage or an explicit waiver
aperture_decision explains all selected nodes
unselected_ready nodes have non-selection reasons
no blocking graph_debt
```

When graph intelligence cannot be computed:

```text
execution_allowed = no
denial_reasons includes graph_intelligence_unavailable
```

A list of selected IDs without the graph fields is `ledger_only` and cannot
authorize material mutation.

## 7. Graph analytics

### 7.1 Critical path

Compute the longest dependency path across executable graph nodes under the
current plan and gate. Include blocked nodes when they are downstream of ready
work so the aperture can explain unlock leverage.

Tie-break deterministically by qualified ID.

### 7.2 Parallel width / antichain candidates

Compute the largest or approximated set of currently ready independent nodes.

V1 may use a conservative approximation if it marks:

```text
parallel_width_kind: approximation
```

### 7.3 Downstream unlocks

For each ready node, count downstream nodes that would become ready if that
node completed and all other current facts remained fixed.

### 7.4 Components

Emit connected components for the plan-local graph and cross-plan blockers
where present.

### 7.5 High-fanout and articulation nodes

Emit advisory lists to help agents understand graph leverage. These do not by
themselves grant execution authority.

## 8. Proof cut

The proof cut is the smallest proof set currently known to certify the selected
frontier at the active gate.

V1 can emit:

```text
exact
approximation
unavailable
```

Rules:

- exact requires a proof-obligation graph and deterministic cut algorithm;
- approximation requires named basis and invalidators;
- unavailable denies material mutation;
- waived proof obligations must cite explicit waiver IDs and scopes.

## 9. GRR-v1 graph repair receipt

When intake, graph audit, graph patch, aperture compilation, or GCR compilation
fails, emit a graph repair receipt:

```yaml
graph_repair_receipt:
  receipt_version: GRR-v1
  repair_id:
  workspace:
    workspace_id:
    workspace_sequence:
  plan_id:
  plan_sequence:
  command:
  failure_class:
    intake_parser_failure |
    intake_semantic_failure |
    graph_audit_failure |
    aperture_compile_failure |
    stale_fingerprint |
    missing_capability |
    missing_proof_cut |
    missing_claim |
    workspace_conflict |
    unknown
  observed_exit_code:
  blocking_debt: []
  graph_invariants_lost: []
  repair_actions: []
  waived_items: []
  current_status:
    blocked |
    repaired |
    waived_for_readonly |
    migration_only
  execution_allowed: false
```

Graph repair receipts are persisted under:

```text
.ledger/st/plans/<plan-id>/repair/<repair-id>.json
```

or in legacy mode beside the legacy file's explicit repair output path.

## 10. Ledger-only mode

Ledger-only mode is allowed for:

```text
migration
reporting
manual graph repair
read-only inspection
```

Ledger-only mode is forbidden for material mutation.

A ledger-only receipt must include:

```yaml
ledger_mode:
  active: true
  reason:
  allowed_operations: []
  material_execution_allowed: false
```

## 11. AMR-v1 artifact maintenance receipt

When a command touches workflow artifacts whose path names could be mistaken
for workflow/controller use, emit or support recording:

```yaml
st_artifact_maintenance_receipt:
  receipt_version: AMR-v1
  maintenance_id:
  workspace:
  operation:
    inspect |
    migrate |
    repair |
    delete_sidecar |
    archive |
    validate
  governing_workflow: st
  artifact_paths: []
  mentioned_workflow_names: []
  activation_signal: false
  controller_invocation: false
  reason:
  evidence_refs: []
```

Primary trigger examples:

```text
.step/st-plan.jsonl
.step/*st-plan*.jsonl
.step/resolve-c3-st-plan.jsonl
.ledger/st/**
```

`seq` should classify AMR-v1 as `artifact_under_repair`, not live workflow
entry for the mentioned workflow name.

## 12. CLI surface

Add:

```bash
st graph receipt \
  --workspace .ledger/st \
  --plan <plan-id> \
  --claim <claim-id> \
  --session <session-id> \
  --format json

st graph repair \
  --workspace .ledger/st \
  --plan <plan-id> \
  --from-last-failure \
  --format json

st artifact-maintenance record \
  --workspace .ledger/st \
  --operation delete_sidecar \
  --path .step/resolve-c3-st-plan.jsonl \
  --mentioned-workflow resolve-c3 \
  --reason "duplicate sidecar durable state" \
  --format json
```

`st compile aperture` should embed the same GCR-v2 graph-intelligence payload
when claim/session scope is provided.

## 13. README updates

Update `apps/st/README.md` to distinguish:

```text
GCR-v2 authority receipt
ledger-only plan preview
GRR-v1 graph repair receipt
AMR-v1 artifact maintenance receipt
```

Replace any wording that implies selected IDs plus fencing alone are sufficient
for material execution.

## 14. Tests

1. Valid graph-intelligence-complete GCR-v2.
2. GCR-v2 missing `unselected_ready` denies execution.
3. GCR-v2 selected node not in ready frontier denies execution.
4. Missing proof cut denies execution.
5. Approximate proof cut permits only with approximation reason.
6. Ready but unselected node without reason denies execution.
7. Critical path tie-break deterministic.
8. Parallel-width approximation deterministic.
9. Downstream unlock counts for simple DAG.
10. Components for disconnected graph.
11. Cross-plan blocker appears in blocked frontier.
12. Graph debt blocks material GCR.
13. Intake parser failure emits GRR-v1.
14. Graph audit failure emits GRR-v1.
15. Aperture compile failure emits GRR-v1.
16. GRR repaired status permits re-run but not retroactive mutation.
17. Ledger-only mode blocks mutation.
18. AMR-v1 for `.step/resolve-c3-st-plan.jsonl`.
19. AMR path mention does not set workflow activation signal.
20. AMR with actual controller invocation remains distinct.
21. `capabilities` advertises new features only when implemented.
22. JSON schema examples round-trip.
23. GCR output stable ordering.
24. Exit code 2 for graph-control denial.
25. Legacy single-plan read-only receipt works without `.ledger/st`.

## 15. Acceptance criteria

Accepted when:

1. Material `st compile aperture` cannot produce `execution_allowed=yes` without
   graph intelligence and proof cut.
2. Every graph compilation failure can be represented as GRR-v1.
3. Artifact maintenance involving workflow-named files can be represented as
   AMR-v1.
4. Capabilities expose the implemented surfaces.
5. `$seq` can distinguish graph-control, graph-repair, and artifact-maintenance
   evidence without transcript scraping.
6. `zig build test-st` and `zig build build-st -Doptimize=ReleaseFast` pass.
