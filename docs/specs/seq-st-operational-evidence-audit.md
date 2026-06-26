# SPEC: `$seq` Audit Support for `$st` Operational Graph Gates

Spec ID: `SEQ-ST-OPERATIONAL-EVIDENCE-v1`  
Target repository: `tkersey/skills-zig`  
Target app: `apps/seq`  
Depends on: `ST-OPERATIONAL-GRAPH-GATES-v1`

## 1. Executive directive

Teach `seq` to distinguish three separate `$st` evidence classes:

```text
graph_control
  GCR-v2 graph-intelligence receipt that can authorize material execution

graph_repair
  GRR-v1 receipt proving graph/intake/audit/aperture failure and repair state

artifact_maintenance
  AMR-v1 receipt proving a workflow-named file was repaired/migrated without
  activating that named workflow/controller
```

The audit must stop treating path names, filenames, or tool success snippets as
sufficient workflow/controller evidence.

## 2. Goals

1. Parse GCR-v2 graph-intelligence fields.
2. Detect ledger-only GCRs used for material mutation.
3. Parse GRR-v1 and expose graph failure/repair state.
4. Parse AMR-v1 and classify artifact-under-repair evidence.
5. Prevent `.step/resolve-c3-st-plan.jsonl` style false positives.
6. Emit per-count evidence refs for required/entered/closed classifier buckets.
7. Add query datasets for graph control, graph repair, and artifact maintenance.
8. Support strict-mode failures for mutation without current graph control.
9. Preserve protocol separation for legacy `.step` sessions.

## 3. Non-goals

1. Do not infer hidden controller execution from filenames.
2. Do not judge historical sessions by newer receipt requirements unless the
   active skill/CLI capability required them.
3. Do not replace `review-compiler-audit`; feed it better provenance.
4. Do not require full `$st` workspace adoption to classify legacy artifact
   maintenance.

## 4. Capabilities

Extend `seq capabilities --format json`:

```yaml
seq_capabilities:
  features:
    st_graph_control_receipt_v1: true
    st_graph_repair_receipt_v1: true
    st_artifact_maintenance_receipt_v1: true
    st_ledger_only_detection_v1: true
    workflow_filename_false_positive_guard_v1: true
    c3_count_evidence_refs_v1: true
```

## 5. Datasets

### 5.1 `st_graph_control_receipts`

```yaml
gcr_id:
workspace_id:
plan_id:
session_id:
claim_id:
fencing_token:
workspace_sequence:
plan_sequence:
branch_epoch:
ready_frontier: []
selected_frontier: []
unselected_ready: []
blocked_frontier: []
critical_path: []
parallel_width:
minimum_proof_cut: []
proof_cut_kind:
execution_allowed:
denial_reasons: []
ledger_only:
evidence_refs: []
```

### 5.2 `st_graph_repair_receipts`

```yaml
repair_id:
workspace_id:
plan_id:
command:
failure_class:
blocking_debt: []
graph_invariants_lost: []
repair_actions: []
current_status:
execution_allowed:
evidence_refs: []
```

### 5.3 `st_artifact_maintenance_receipts`

```yaml
maintenance_id:
workspace_id:
operation:
governing_workflow:
artifact_paths: []
mentioned_workflow_names: []
activation_signal:
controller_invocation:
reason:
evidence_refs: []
```

### 5.4 `workflow_provenance_evidence`

Normalize evidence used by review/compiler classifiers:

```yaml
session_id:
workflow_name:
evidence_class:
  controller_invocation |
  controller_event |
  controller_state |
  explicit_workflow_declaration |
  artifact_under_repair |
  filename_or_path_mention |
  tool_success_snippet |
  absent
source:
timestamp:
ref:
reason:
```

## 6. Classifier rules

### 6.1 Controller-grade evidence

Count as true workflow/controller evidence only:

```text
controller invocation
controller event/state transition
explicit workflow declaration
controller receipt
```

### 6.2 Non-controller evidence

Never sufficient by itself:

```text
filename/path mention
git diff touching a workflow-named file
apply_patch deleting a workflow-named file
cat/jq/rg of a workflow-named file
Exit code: 0
Chunk ID
artifact maintenance receipt with activation_signal=false
```

### 6.3 Artifact maintenance

AMR-v1 sets:

```text
workflow_provenance = artifact_under_repair
```

and should be excluded from true workflow denominator unless independent
controller-grade evidence exists.

## 7. Audits

Add or extend:

```bash
seq st-workspace-audit --mode graph-control|repair|artifact-maintenance|report
seq review-compiler-audit --emit-count-evidence --format json
seq workflow-audit --mode provenance --workflow <name>
```

## 8. Strict failures

Exit `2` when current/new-protocol sessions show:

```text
material mutation without current GCR-v2
material mutation with ledger_only GCR
material mutation after open GRR-v1
artifact_under_repair counted as workflow entry
C3 required derived from filename/path only
closed workflow row lacking controller-grade closure evidence
```

## 9. Report output

Reports must include:

```text
included session IDs
per-count evidence refs
workflow provenance class
artifact-under-repair exclusions
ledger-only graph-control denials
open graph repair blockers
```

## 10. Tests

1. True GCR-v2 graph-control receipt.
2. Ledger-only GCR denied for mutation.
3. GRR-v1 open repair blocker.
4. GRR-v1 repaired then GCR-current flow.
5. AMR-v1 for `.step/resolve-c3-st-plan.jsonl`.
6. Filename-only false positive excluded.
7. Actual `resolve-c3` controller invocation included.
8. Mixed AMR plus controller invocation classified as controller evidence.
9. `Exit code: 0` alone not sufficient.
10. Included-row evidence refs emitted.
11. Legacy session without new receipts not retroactively failed.
12. Strict-mode current violation exits 2.

## 11. Acceptance criteria

Accepted when:

1. The false-positive C3 source row caused by `.step/resolve-c3-st-plan.jsonl`
   is excluded or classified as artifact-under-repair.
2. `review-compiler-audit` exposes included rows and per-count evidence refs.
3. `seq` can report whether `$st` material mutation had a current
   graph-intelligence-complete GCR.
4. Strict mode catches ledger-only material execution.
5. Existing reports retain backward compatibility.
