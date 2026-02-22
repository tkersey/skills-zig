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

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_io -Mroot=apps/lift/scripts/bench_stats.zig -Mcore_io=libs/core/src/io_helpers.zig -ffuzz --test-filter "fuzz "
```
