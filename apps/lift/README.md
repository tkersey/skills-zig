# lift-zig-cli

Zig CLI utilities extracted from dotfiles LIFT skill.

## Files
- `scripts/bench_stats.zig`
- `scripts/perf_report.zig`
- `scripts/perf_bench_stats.zig`

## Validation

```bash
zig build build-lift -Doptimize=ReleaseFast
zig build test-lift
bash apps/lift/scripts/perf/bench_stats_gate.sh

# Bounded native fuzz qualification (matches CI behavior).
.github/scripts/linux_fuzz_gate.sh -- zig build test-lift-bench-stats \
  -Doptimize=ReleaseSafe --fuzz=100K --summary all
```
