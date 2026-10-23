# CAS observation allocation benchmark

This benchmark isolates request construction and notification-buffer ownership for
1,000 inquiry polling cycles. It uses synthetic data and performs no RPC, account,
model, filesystem-log, or sleep operations. It does not measure end-to-end inquiry
latency or full-response parsing.

The baseline reproduces the allocation and cleanup ordering of
`waitForTurnObservation` in `apps/cas/scripts/cas_session_inquiry.zig` at
`8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb`. The candidate reproduces its parameter
hoisting and retained notification capacity and imports the current production
`turn_observation.clearNotifications` implementation. This is a mechanism benchmark,
not execution of the full polling function. Both paths check the exact request
bytes and consume identical synthetic notification bytes.

From the repository root, with Zig 0.17.0:

```sh
zig run -O fast \
  --dep observation \
  -Mroot=docs/engineering/cli-optimizations/cas-observation/benchmark.zig \
  -Mobservation=apps/cas/scripts/turn_observation.zig
```

[results.tsv](results.tsv) contains the final captured counts from native macOS
ARM64 with Zig 0.17.0 and its process allocator. `allocations` counts successful
allocator allocation calls; `allocated_bytes` includes positive resize/remap byte
deltas and is cumulative, not peak or retained memory. Every measurement verifies
that allocated and freed bytes balance. Counts may depend on allocator and
toolchain behavior; the fixture and operations are fixed.

| Notifications per poll | Baseline allocations | Candidate allocations | Reduction |
|---:|---:|---:|---:|
| 0 | 1,000 | 1 | 99.9% |
| 8 | 10,000 | 8,002 | 19.98% |
| 64 | 66,000 | 64,002 | 3.03% |

The candidate retains request bytes and notification-array capacity during wait
intervals. Individual notification payloads are still freed after each poll.
Capacity remains subject to the runtime's existing captured-notification limit.
The production change preserves full snapshot requests, event-log contents and
order, timeout behavior, and polling cadence. No history-size or network-latency
improvement is claimed.
