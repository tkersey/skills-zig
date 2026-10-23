# CLI optimization measurements

Baseline: `8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb`. Candidate: the implementation
and source hashes published with this report. Zig 0.17.0, ReleaseFast, native
Apple M2 Pro ARM64, macOS 27.2. Build work for this task was stopped during timing;
unrelated host workloads remained. Raw samples and reproduction commands are linked
below. Positive percentages mean a reduction; negative percentages mean an increase.
Component timings do not establish whole-command or service latency.

[Source and binary hashes](source-manifest.json) bind the captured candidate.

## Changes

- Seq retains only demanded trace fields, while parsing and validating every record.
- Seq graph top-k shares heap repair with streaming Seq and Ledger. Small selections
  retain k indexes; selections above half the rows sort indexes once and copy the
  selected prefix. Incomparable or nonfinite keys preserve the full-sort ordering.
- Ledger borrows sort keys while deciding admission and owns keys only for retained rows.
- Lift selects bootstrap order statistics and reuses three scratch arrays across
  p50/p95/p99. Signed zero and nonfinite samples keep the prior sort path.
- CAS reads bounded chunks through an incremental JSONL cursor, reuses polling
  parameter and notification storage, and shares turn lookup with explicit duplicate policy.
- SIWC owns a stable HTTP client with at most two idle connections. Token/revocation
  POSTs start fresh and never replay. An idle GET connection can recover once,
  before response bytes arrive, within the original deadline.
- Memory-note and migration share a sorted inventory and bounded reusable parsing
  scratch. Deduplication precedes fresh-note allocation; exact size rejection still
  precedes mutation. Fresh admission performs a counting serialization before rendering.
- Seq and Ledger share cache-envelope transport while retaining their own codecs,
  keys and error policies. CAS shares Darwin process preparation and status handling;
  caller-owned directories, environments, capture and detachment stay explicit.
  The unused delegate helper was removed. No runtime gain is claimed for these extractions.

## Seq trace retention

[Method and runner](seq/README.md) · [all samples](seq/results.json). Eleven paired
whole-process samples per case, alternating order. Peak RSS is measured by macOS
`time -l`. The full-row query is a control.

| Query | Median ms before → after | Time reduction | Peak RSS bytes before → after | RSS reduction |
|---|---:|---:|---:|---:|
| turns-64-projected | 6.273 → 5.961 | 4.97% | 3,391,488 → 2,686,976 | 20.77% |
| turns-512-projected | 17.747 → 16.567 | 6.65% | 14,450,688 → 3,063,808 | 78.80% |
| messages-512-projected | 37.881 → 29.705 | 21.58% | 42,614,784 → 16,039,936 | 62.36% |
| events-512-projected | 38.099 → 30.194 | 20.75% | 42,827,776 → 16,220,160 | 62.13% |
| turns-64-full | 7.427 → 7.535 | -1.45% | 4,128,768 → 4,177,920 | -1.19% |

## Ordered selection

[Method and reproduction](selection/README.md) · [final summary](selection/results/summary.json)
· [raw captures](selection/results/raw). Sixty samples per side and case. Every
graph output digest and Ledger fixture/output digest matched. The graph timings
include graph setup, selection and output copying. Allocation bytes are cumulative
requested bytes, not peak RSS. All graph cases reduce allocation attempts from 10
to 9 (10%). Superseded heap-only measurements are labeled separately.

Large selections improve across the measured k values. Tiny high-k cases are
16–54% slower in this run, an absolute increase of 0.35–0.88 µs; no uniform
latency improvement is claimed.

| Rows | Width | k | Order | Median µs before → after | Time reduction | Allocation bytes before → after | Byte reduction |
|---:|---:|---:|---|---:|---:|---:|---:|
| 32 | 3 | 1 | asc | 1.709 → 0.917 | 46.34% | 2,852 → 300 | 89.48% |
| 32 | 3 | 1 | desc | 1.500 → 0.750 | 50.00% | 2,852 → 300 | 89.48% |
| 32 | 3 | 10 | asc | 1.667 → 1.417 | 15.03% | 4,148 → 1,668 | 59.79% |
| 32 | 3 | 10 | desc | 1.438 → 1.459 | -1.50% | 4,148 → 1,668 | 59.79% |
| 32 | 3 | 16 | asc | 1.625 → 1.833 | -12.80% | 5,012 → 2,580 | 48.52% |
| 32 | 3 | 16 | desc | 1.438 → 1.667 | -15.93% | 5,012 → 2,580 | 48.52% |
| 32 | 3 | 31 | asc | 1.708 → 2.438 | -42.74% | 7,172 → 4,868 | 32.12% |
| 32 | 3 | 31 | desc | 1.417 → 1.792 | -26.46% | 7,172 → 4,868 | 32.12% |
| 32 | 3 | 32 | asc | 1.625 → 2.500 | -53.85% | 7,316 → 5,012 | 31.49% |
| 32 | 3 | 32 | desc | 1.417 → 1.812 | -27.91% | 7,316 → 5,012 | 31.49% |
| 32 | 32 | 1 | asc | 1.917 → 0.729 | 61.97% | 26,516 → 1,692 | 93.62% |
| 32 | 32 | 1 | desc | 1.708 → 0.646 | 62.18% | 26,516 → 1,692 | 93.62% |
| 32 | 32 | 10 | asc | 2.042 → 1.458 | 28.57% | 40,340 → 15,588 | 61.36% |
| 32 | 32 | 10 | desc | 1.875 → 1.583 | 15.57% | 40,340 → 15,588 | 61.36% |
| 32 | 32 | 16 | asc | 2.167 → 2.021 | 6.74% | 49,556 → 24,852 | 49.85% |
| 32 | 32 | 16 | desc | 2.000 → 2.062 | -3.10% | 49,556 → 24,852 | 49.85% |
| 32 | 32 | 31 | asc | 2.438 → 2.833 | -16.25% | 72,596 → 48,020 | 33.85% |
| 32 | 32 | 31 | desc | 2.250 → 2.604 | -15.73% | 72,596 → 48,020 | 33.85% |
| 32 | 32 | 32 | asc | 2.458 → 2.854 | -16.13% | 74,132 → 49,556 | 33.15% |
| 32 | 32 | 32 | desc | 2.250 → 2.624 | -16.64% | 74,132 → 49,556 | 33.15% |
| 16384 | 3 | 1 | asc | 3528.624 → 123.541 | 96.50% | 1,311,012 → 300 | 99.98% |
| 16384 | 3 | 1 | desc | 3467.291 → 85.042 | 97.55% | 1,311,012 → 300 | 99.98% |
| 16384 | 3 | 10 | asc | 3534.563 → 124.188 | 96.49% | 1,312,308 → 1,668 | 99.87% |
| 16384 | 3 | 10 | desc | 3533.500 → 82.772 | 97.66% | 1,312,308 → 1,668 | 99.87% |
| 16384 | 3 | 100 | asc | 3566.334 → 169.729 | 95.24% | 1,325,268 → 15,348 | 98.84% |
| 16384 | 3 | 100 | desc | 3490.459 → 105.312 | 96.98% | 1,325,268 → 15,348 | 98.84% |
| 16384 | 3 | 1000 | asc | 3557.812 → 640.188 | 82.01% | 1,454,868 → 152,148 | 89.54% |
| 16384 | 3 | 1000 | desc | 3496.063 → 516.605 | 85.22% | 1,454,868 → 152,148 | 89.54% |
| 16384 | 3 | 8192 | asc | 3564.750 → 2842.229 | 20.27% | 2,490,516 → 1,245,332 | 50.00% |
| 16384 | 3 | 8192 | desc | 3508.208 → 2741.063 | 21.87% | 2,490,516 → 1,245,332 | 50.00% |
| 16384 | 3 | 16383 | asc | 3581.750 → 3476.938 | 2.93% | 3,670,020 → 2,490,372 | 32.14% |
| 16384 | 3 | 16383 | desc | 3504.938 → 3421.979 | 2.37% | 3,670,020 → 2,490,372 | 32.14% |
| 16384 | 3 | 16384 | asc | 3563.646 → 3495.417 | 1.91% | 3,670,164 → 2,490,516 | 32.14% |
| 16384 | 3 | 16384 | desc | 3510.521 → 3405.709 | 2.99% | 3,670,164 → 2,490,516 | 32.14% |
| 16384 | 32 | 1 | asc | 4301.895 → 102.896 | 97.61% | 12,715,668 → 1,692 | 99.99% |
| 16384 | 32 | 1 | desc | 4575.312 → 69.895 | 98.47% | 12,715,668 → 1,692 | 99.99% |
| 16384 | 32 | 10 | asc | 4470.521 → 105.625 | 97.64% | 12,729,492 → 15,588 | 99.88% |
| 16384 | 32 | 10 | desc | 4491.730 → 71.292 | 98.41% | 12,729,492 → 15,588 | 99.88% |
| 16384 | 32 | 100 | asc | 4485.375 → 156.000 | 96.52% | 12,867,732 → 154,548 | 98.80% |
| 16384 | 32 | 100 | desc | 4561.125 → 97.375 | 97.87% | 12,867,732 → 154,548 | 98.80% |
| 16384 | 32 | 1000 | asc | 4473.480 → 708.792 | 84.16% | 14,250,132 → 1,544,148 | 89.16% |
| 16384 | 32 | 1000 | desc | 4526.062 → 573.250 | 87.33% | 14,250,132 → 1,544,148 | 89.16% |
| 16384 | 32 | 8192 | asc | 4864.145 → 3426.104 | 29.56% | 25,297,044 → 12,648,596 | 50.00% |
| 16384 | 32 | 8192 | desc | 4954.230 → 3400.041 | 31.37% | 25,297,044 → 12,648,596 | 50.00% |
| 16384 | 32 | 16383 | asc | 5341.979 → 4870.105 | 8.83% | 37,878,420 → 25,295,508 | 33.22% |
| 16384 | 32 | 16383 | desc | 5249.292 → 4836.583 | 7.86% | 37,878,420 → 25,295,508 | 33.22% |
| 16384 | 32 | 16384 | asc | 5227.270 → 4871.812 | 6.80% | 37,879,956 → 25,297,044 | 33.22% |
| 16384 | 32 | 16384 | desc | 5262.688 → 4847.479 | 7.89% | 37,879,956 → 25,297,044 | 33.22% |

Ledger retains validation for rejected rows. Its whole projection latency is
effectively flat in this workload; the demonstrated improvement is allocation count.

| Ledger case | Median ms before → after | Time reduction | Allocations before → after | Allocation reduction |
|---|---:|---:|---:|---:|
| ledger-topk-16384-k1 | 58.393 → 59.039 | -1.11% | 229,796 → 213,459 | 7.11% |
| ledger-topk-16384-k10 | 59.217 → 59.348 | -0.22% | 229,918 → 213,621 | 7.09% |
| ledger-topk-16384-k100 | 59.848 → 58.782 | 1.78% | 231,525 → 215,762 | 6.81% |
| ledger-topk-16384-k1000 | 63.055 → 63.049 | 0.01% | 241,002 → 228,396 | 5.23% |
| ledger-topk-32-k10 | 0.301 → 0.303 | -0.73% | 763 → 743 | 2.62% |

## Lift bootstrap

[Reproduction helper](../../../apps/lift/perf/compare_bootstrap.py)
· [raw results](../../../apps/lift/perf/bootstrap/artifacts/optimization.json).
Nine paired whole-process samples per case after one warmup, with a fixed seed.
All 16 cases had identical stdout, stderr and status. Normal cases use 1,000
bootstrap samples; special cases use 73. Scratch allocation tests separately prove
9 → 3 allocations (66.67%) across the three intervals, with unchanged peak scratch size.

| Distribution / count | Median ms before → after | Time reduction |
|---|---:|---:|
| uniform-16 | 6.063 → 6.059 | 0.07% |
| duplicates-16 | 6.863 → 5.698 | 16.97% |
| descending-16 | 5.575 → 5.537 | 0.68% |
| uniform-128 | 29.976 → 16.223 | 45.88% |
| duplicates-128 | 27.334 → 14.259 | 47.83% |
| descending-128 | 28.670 → 15.449 | 46.11% |
| uniform-1024 | 291.958 → 86.310 | 70.44% |
| duplicates-1024 | 207.472 → 77.664 | 62.57% |
| descending-1024 | 292.177 → 86.179 | 70.50% |
| uniform-4096 | 1437.962 → 326.920 | 77.27% |
| duplicates-4096 | 880.875 → 292.851 | 66.75% |
| descending-4096 | 1438.312 → 325.422 | 77.37% |
| signed-zero | 3.578 → 3.853 | -7.70% |
| extremes | 3.611 → 3.743 | -3.63% |
| infinity | 3.494 → 3.418 | 2.17% |
| singleton | 3.302 → 3.489 | -5.66% |

Tiny and special-case timings are dominated by startup and noise; they are
compatibility controls rather than evidence of a general speedup.

## CAS framing and polling

[Framing method, full measurements and tradeoffs](cas-framing/README.md)
· [raw samples](cas-framing/raw). Seven samples per side and size call the actual
framing implementation with synthetic unseekable input. Read counts are synthetic
operations, not measured syscalls. JSON parsing, scheduling and server work are excluded.

| Frame | Median ns before → after | Time reduction | Streaming reads before → after | Read reduction |
|---|---:|---:|---:|---:|
| 1,024 B | 39,042 → 292 | 99.2521% | 1,024 → 1 | 99.9023% |
| 65,536 B | 42,657,625 → 32,083 | 99.9248% | 65,536 → 16 | 99.9756% |
| 1,048,576 B | 10,358,362,708 → 394,041 | 99.9962% | 1,048,576 → 256 | 99.9756% |

Positional probes fall from one per input byte to zero (100%). Allocation
attempts fall 5 → 2 (60%), 21 → 10 (52.38%), and 35 → 24 (31.43%).
The 1-KiB case requests 3,139 → 7,295 bytes (+132.40%) because of chunk reservation;
64-KiB median requested bytes fall 492,418 → 367,743 (25.32%), and 1-MiB bytes
fall 8,753,992 → 8,528,767 (2.57%). These counters include resize/remap attempts.

[Polling allocation method and results](cas-observation/README.md) isolate request
and notification storage over 1,000 polls, excluding RPC, parsing, logging and sleep.

| Notifications per poll | Allocations before → after | Reduction | Allocated bytes before → after | Byte reduction |
|---:|---:|---:|---:|---:|
| 0 | 1,000 → 1 | 99.90% | 131,000 → 131 | 99.90% |
| 8 | 10,000 → 8,002 | 19.98% | 1,083,000 → 808,275 | 25.37% |
| 64 | 66,000 → 64,002 | 3.03% | 7,795,000 → 6,465,331 | 17.06% |

Polling retains request bytes and notification-array capacity between polls;
individual payloads are freed. Full snapshots, log ordering and polling cadence remain.

## SIWC HTTP sessions

[Method, reproduction and results](siwc/README.md) · [all raw samples](siwc/results).
The synthetic token/discovery/keys sequence uses 3 → 1 connections (66.67% fewer)
in every sample. Across 125 samples per side, median loopback transport time is
472,583 → 246,459 ns (47.85% lower). Baseline p10–p90 is 356,433–720,866 ns;
candidate p10–p90 is 190,108–519,650 ns. This includes client setup/destruction but
excludes TLS and remote authentication. Shared-host variation is substantial.

## Memory-note inventory

[Method and runner](memory-note/README.md) · [raw samples](memory-note/results.json).
Seven alternating samples per binary, case and note count. All outputs agree
after validating and normalizing generated clock fields. These warm-filesystem
whole-process timings establish no general latency improvement. Reusable scratch
tests show zero additional backing allocations across 32 warmed record visits.
The fresh-append cases include the extra counting serialization and show no
material consistent regression in this run.

| Operation | Notes | Median ms before → after | Observed time reduction |
|---|---:|---:|---:|
| list | 32 | 4.232 → 4.442 | -4.95% |
| show | 32 | 4.053 → 4.283 | -5.67% |
| duplicate | 32 | 4.025 → 4.137 | -2.77% |
| fresh | 32 | 4.193 → 4.161 | 0.76% |
| fresh-large | 32 | 4.883 → 4.631 | 5.16% |
| migration-preview | 32 | 4.030 → 3.992 | 0.94% |
| list | 1024 | 34.538 → 34.391 | 0.43% |
| show | 1024 | 33.329 → 33.094 | 0.71% |
| duplicate | 1024 | 33.212 → 33.169 | 0.13% |
| fresh | 1024 | 34.518 → 34.629 | -0.32% |
| fresh-large | 1024 | 34.216 → 33.870 | 1.01% |
| migration-preview | 1024 | 34.456 → 34.462 | -0.02% |
| list | 4096 | 133.530 → 131.739 | 1.34% |
| show | 4096 | 132.338 → 137.844 | -4.16% |
| duplicate | 4096 | 131.144 → 130.235 | 0.69% |
| fresh | 4096 | 131.532 → 129.198 | 1.77% |
| fresh-large | 4096 | 144.188 → 138.008 | 4.29% |
| migration-preview | 4096 | 137.727 → 136.628 | 0.80% |

## Preserved contracts and verification

CLI schemas, cache keys/envelope bytes, ordering and tie rules, error categories,
source validation, authorization, locks and recovery remain governed by their
existing owners. CAS still enforces its 8-MiB message bound and caller deadlines.
Memory-note still admits at most 10,000 notes of 1 MiB each; retained parser scratch
is capped at 8 MiB. SIWC keeps its 1-MiB response, 128-KiB request and 30-second
deadline limits. Selection uses bounded index storage; bootstrap partitioning is
iterative with a logarithmic partition budget and sort fallback.

Local qualification includes the full repository test target, real local Codex
transport and inquiry integration, SIWC Debug/ReleaseSafe and offline process tests,
757 Seq differential queries, memory-note CLI/recovery/migration checks, standalone
Seq/install-prefix admission, release classifier/archive tests, lint, formatting and
TigerStyle. Native Linux and packaged macOS release qualification run in GitHub CI.
Exact final command results are recorded in the pull request.

Releases: Seq 1.2.4, Lift 0.4.2, CAS 0.8.2, Ledger 1.5.5, memory-note 0.3.4,
and SIWC 0.1.2. There is no cache-schema or account-format migration.

Early rejection of trace files, replacing full CAS snapshots, and cached SIWC
account records were not adopted: they would change malformed-source reporting,
observable evidence, or identity/removal checks. Persistent indexes, a multicall
CAS executable and CI/release workflow redesign remain separate work.
