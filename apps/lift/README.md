# Lift statistics utility

Lift ships one executable, `bench_stats`, for raw numeric sample summaries and
baseline/candidate comparisons. The package remains `tkersey/tap/lift`, with
`lift-v*` releases; there is no `lift` executable. Requested performance reports
use Tune's native report template.

## Source and validation

- `scripts/bench_stats.zig`: shipped statistics utility.
- `scripts/perf_bench_stats.zig`: development performance harness.

Run from the repository root:

```bash
zig build build-lift -Doptimize=fast
zig build test-lift
zig build bench-lift-bench-stats -Doptimize=fast -- --help
bash apps/lift/scripts/perf/bench_stats_gate.sh

# Bounded native Linux fuzz qualification (matches CI behavior).
.github/scripts/linux_fuzz_gate.sh -- zig build test-lift-bench-stats \
  -Doptimize=safe --fuzz=100K --summary all
```

The benchmark target creates no install artifact. Its workload is
`perf/bench_stats/workload_config.json`, with the retained baseline in
`perf/bench_stats/artifacts/baseline.json`. The gate can be invoked by absolute
script path from any working directory. Configuration, baseline, and result
paths supplied through `LIFT_BENCH_CONFIG_PATH`, `LIFT_BENCH_BASELINE_ARTIFACT`,
and `LIFT_BENCH_TREND_ARTIFACT` are absolute or relative to `apps/lift`.
For direct benchmark execution, pass absolute `--config` and `--artifact` paths.
