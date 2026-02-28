# mesh

Zig CLI for plan-driven orchestration helpers (`budget`, `plan_sync`, `slice`, `wave`, `run_csv`, `ledger`, `replay`).

Triplet-first orchestration support is built in for coding lanes (`coder`, `fixer`, `integrator`) with budget-aware degrade/restore logic.

## Build

```bash
zig build build-mesh -Doptimize=ReleaseFast
```

## Run

```bash
zig build run-mesh -- --help
```

## Triplet Examples

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

# Emit fixer lane rows with width 3
zig build run-mesh -- wave \
  --units-json .mesh/units.json \
  --csv-path .mesh/wave-fixer.csv \
  --max-active 4 \
  --lane fixer \
  --triplet-width 3

# Prepare output CSV with strict required headers including
# cohort_id/triplet_index/candidate_id/role_in_lane/challenge_targets/quorum_rule
zig build run-mesh -- run_csv \
  --csv-path .mesh/wave-fixer.csv \
  --output-csv-path .mesh/wave-fixer-out.csv
```
