# mesh

Zig CLI for plan-driven streaming orchestration helpers (`budget`, `plan_sync`, `slice`, `wave`, `run_csv`, `ledger`, `replay`, `orchplan_to_units`, `prepare_crfip_batch`, `doctor`, `lane_completeness_lint`, `contract_drift_lint`, `migration_gate`).

Lane support includes `coder`, `reducer`, `locksmith`, `applier`, `prover`, `fixer`, and `integrator`.
`run_csv` now validates streaming contract headers (`write_scope`, `risk_tier`, `lane`, `base_sha`) and prepares a v2 output skeleton.
It also supports hard preflight gates for concurrency floor and dependency deadlock checks.

## Build

```bash
zig build build-mesh -Doptimize=ReleaseFast
```

## Run

```bash
zig build build-mesh -Doptimize=ReleaseFast
./zig-out/bin/mesh --help
```

## Streaming Batch Examples

```bash
# Budget clamp + triplet width decision
./zig-out/bin/mesh budget \
  --remaining-five-hour 42 \
  --remaining-weekly 38 \
  --max-threads 12 \
  --previous-triplet-width 3 \
  --prior-wave-instability false \
  --consecutive-unstable-waves 0 \
  --consecutive-clean-waves 1

# Emit reducer lane rows with width 3
./zig-out/bin/mesh wave \
  --units-json .mesh/units.json \
  --csv-path .mesh/batch-reducer.csv \
  --max-active 4 \
  --lane reducer \
  --triplet-width 3

# Prepare output CSV with strict required streaming headers including
# write_scope/risk_tier/candidate_id/triplet_index/lane/base_sha
./zig-out/bin/mesh run_csv \
  --csv-path .mesh/batch-reducer.csv \
  --output-csv-path .mesh/batch-reducer-out.csv

# Enforce floor gate (fails non-zero when applicable and peak < threshold)
./zig-out/bin/mesh run_csv \
  --csv-path .mesh/batch-reducer.csv \
  --output-csv-path .mesh/batch-reducer-out.csv \
  --max-concurrency 6 \
  --runnable-units 6 \
  --floor-threshold 3 \
  --fail-on-floor

# Optional deadlock preflight over dependency CSV
./zig-out/bin/mesh run_csv \
  --csv-path .mesh/batch-reducer.csv \
  --output-csv-path .mesh/batch-reducer-out.csv \
  --deps-csv .mesh/wave-deps.csv
```

`run_csv` response now includes:
- `spawn_substrate`, `mesh_truth_verdict`
- `max_concurrency`, `runnable_units`, `effective_peak`
- `floor_threshold`, `floor_applicable`, `floor_result`
- `deps_check_status` (`pass` or `skipped`)

## Mesh Cutover Helpers

```bash
# Convert OrchPlan (json/yaml) into units payload
./zig-out/bin/mesh orchplan_to_units \
  --orchplan /tmp/orchplan.yaml \
  --output-json /tmp/units.json

# Prepare durable CRFIP candidate rows + output skeleton
./zig-out/bin/mesh prepare_crfip_batch \
  --units-json /tmp/units.json \
  --max-active 6 \
  --max-concurrency 12 \
  --fail-on-floor

# Lane completeness lint
./zig-out/bin/mesh lane_completeness_lint \
  --check crfip \
  --require-spawn-substrate \
  .mesh/*.exec.out.csv

# Postmortem doctor
./zig-out/bin/mesh doctor \
  --rollout-jsonl /absolute/path/to/rollout.jsonl \
  --expect-mesh-truth \
  --require-artifacts \
  --require-archived-paths \
  --lane-check crfip \
  --require-spawn-substrate
```
