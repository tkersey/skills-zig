# mesh

Zig CLI for plan-driven streaming orchestration helpers (`budget`, `plan_sync`, `slice`, `wave`, `run_csv`, `ledger`, `replay`).

Lane support includes `coder`, `reducer`, `locksmith`, `applier`, `prover`, `fixer`, and `integrator`.
`run_csv` now validates streaming contract headers (`write_scope`, `risk_tier`, `lane`, `base_sha`) and prepares a v2 output skeleton.

## Build

```bash
zig build build-mesh -Doptimize=ReleaseFast
```

## Run

```bash
zig build run-mesh -- --help
```

## Streaming Batch Examples

```bash
# Budget clamp + triplet width decision
zig build run-mesh -- budget \
  --remaining-five-hour 42 \
  --remaining-weekly 38 \
  --max-threads 12 \
  --previous-triplet-width 3 \
  --prior-wave-instability false \
  --consecutive-unstable-waves 0 \
  --consecutive-clean-waves 1

# Emit reducer lane rows with width 3
zig build run-mesh -- wave \
  --units-json .mesh/units.json \
  --csv-path .mesh/batch-reducer.csv \
  --max-active 4 \
  --lane reducer \
  --triplet-width 3

# Prepare output CSV with strict required streaming headers including
# write_scope/risk_tier/candidate_id/triplet_index/lane/base_sha
zig build run-mesh -- run_csv \
  --csv-path .mesh/batch-reducer.csv \
  --output-csv-path .mesh/batch-reducer-out.csv
```
