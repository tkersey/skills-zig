# Ordered selection measurements

These synthetic drivers compare the graph selection and Ledger projection paths
against revision `8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb`. They use the product's
public modules with unmodified implementation sources.

With Zig 0.17.0 and uv available, run from the repository root:

```sh
uv run --no-project docs/engineering/cli-optimizations/selection/reproduce.py prepare \
  --output /tmp/selection-comparison --candidate HEAD
uv run --no-project docs/engineering/cli-optimizations/selection/reproduce.py measure \
  --output /tmp/selection-comparison
```

`prepare` requires a new output directory and builds separate ReleaseFast source
snapshots. Set `--candidate` to the commit being evaluated. `measure` requires the
prepared directory and runs baseline, candidate, candidate, baseline. Pause other
builds before measuring. The script verifies matching graph output digests and
Ledger fixture/output digests, then writes raw samples and a combined summary.

The graph driver executes a scan followed by top-k through
`relation_graph.executeTarget`. Cases cover 32 and 16,384 rows; widths 3 and 32;
ascending and descending order; nulls and stable ties; and k values 1, 10, 100,
1,000, n/2, n−1 and n where applicable. Its timing includes graph initialization,
selection and output copying. Input construction, output hashing and the final
output deallocation are outside the timed region. Allocation bytes count requested
allocation/resize/remap bytes, not peak resident memory.

The Ledger driver is the repository's `tools/optimization_driver.zig`. It measures
projection execution with prepared plans and bindings, using 16,384 rows at k=1,
10, 100 and 1,000, plus a 32-row k=10 case. Each row has a 1-KiB payload and two
integer sort keys. This includes parsing and projection work; process startup,
definition compilation and fixture setup are outside the timed region.

Each process performs three warmups and 30 measured calls per case. The two
processes per side provide 60 samples per case. These are component measurements
on a shared host, not whole-CLI latency or a service tail-latency estimate.

The committed regression tests separately cover shared heap invariants, graph
equivalence to full sorting, incompatible-key and infinity fallback, NaN heap
exclusion, allocation failure cleanup, losing-row validation, and borrowed
string/exact-number sort keys without per-loser allocation. NaN has no defined
ordering in the existing full-sort comparator and is not passed to that oracle.

## Recorded final result

[Raw captures, summary and environment](results/) record a macOS Apple M2 Pro run
with Zig 0.17.0. All 48 graph output digests and all five Ledger workload/output
digests matched. Task-owned builds were paused; unrelated jobs remained active.
Graph measurements were repeated after introducing the adaptive sorted-prefix
path; Ledger captures were retained because its implementation was unchanged.
The later correction of the NaN test fixture changes only test code; the measured
production functions are unchanged, and the rebuilt Seq release executable has
the same SHA-256 recorded in the [source manifest](../source-manifest.json).

| Case | Baseline p50 | Candidate p50 | Allocation calls | Requested allocation bytes |
| --- | ---: | ---: | ---: | ---: |
| Graph: 16,384 rows, width 3, k=10 ascending | 3.535 ms | 0.124 ms | 10 → 9 | 1,312,308 → 1,668 |
| Graph: 16,384 rows, width 32, k=1,000 ascending | 4.473 ms | 0.709 ms | 10 → 9 | 14,250,132 → 1,544,148 |
| Graph: 16,384 rows, width 3, k=8,192 ascending | 3.565 ms | 2.842 ms | 10 → 9 | 2,490,516 → 1,245,332 |
| Graph: 16,384 rows, width 3, k=16,383 ascending | 3.582 ms | 3.477 ms | 10 → 9 | 3,670,020 → 2,490,372 |
| Graph: 32 rows, width 3, k=32 ascending | 1.62 µs | 2.50 µs | 10 → 9 | 7,316 → 5,012 |
| Ledger: 16,384 rows, k=10 | 59.217 ms | 59.348 ms | 229,918 → 213,621 | Not captured |
| Ledger: 16,384 rows, k=1,000 | 63.055 ms | 63.049 ms | 241,002 → 228,396 | Not captured |

Graph selection at n=16,384 and k=1–1,000 reduced measured p50 by 82–98% across
both widths and directions. Half-size selections improved by 20–31%. Nearly
full selections improved by 2–9%, as did full selections by 2–8%. The adaptive
path sorts row indices and copies only the selected prefix for k>n/2; smaller
selections retain a bounded heap.

Small-case wall times were mixed. At n=32, k=1 improved by 46–62%, while k=31
and k=32 regressed by 16–54% (roughly 0.35–0.88 µs). Some smaller selections also
regressed. The k=n algorithm was already a full index sort before the adaptive
change, so these measurements do not isolate the tiny-input slowdown to heap
selection. Code layout and shared-host effects remain possible contributors.
Allocation calls and requested bytes decreased in every case. These results do
not establish uniform latency improvement.

[Initial graph measurements](results/initial-graph/) are superseded and excluded
from final acceptance. They showed avoidable overhead when almost all rows were
retained, motivating the sorted-prefix successor. The tests now exercise n/2,
n/2+1 and n−1 explicitly, including allocation failure on both algorithm paths.

Ledger reduced allocation calls by 5.2–7.1% on the large cases and 2.6% on the
small case. Measured p50 ranged from 1.8% faster to 1.1% slower, within observed
process variation. The supported Ledger improvement is allocation reduction;
these measurements do not establish lower wall latency. Its existing parser and
payload validation remain part of the measured workload.
