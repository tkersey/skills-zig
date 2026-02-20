# Parity and Performance Report

Date: 2026-02-19

## Differential Parity

Command:

```bash
scripts/parity/run_diff.sh --root ~/.codex/sessions/2026/02/19
```

Result:

- total: 5
- passed: 5
- failed: 0

Artifact: `.zig-cache/parity/results.jsonl`

## Head-to-Head Performance Gate

Command:

```bash
scripts/perf/head_to_head.sh --root testdata/golden/sessions --gate 20 --samples 9 --warmup 1
```

Result:

- overall_p50_speedup_pct: `90.17`
- gate_pct: `20.0`
- status: `PASS`

Per-case p50 speedup:

- query_tool_calls_day_tool: `90.05%`
- query_token_deltas_day: `90.17%`
- query_token_sessions_day: `91.44%`

## Notes

- The performance gate is enforced only after parity passes.
- On much larger real roots, the current Zig implementation may not yet beat Python; this report captures the validated frozen workload gate run above.
