# CAS stdio framing reproduction

This synthetic benchmark calls the actual `Client.readLineAlloc` implementation
with an in-memory unseekable input. It compares the byte-at-a-time reader and
repeated prefix scan with the persistent 4 KiB reader and incremental line cursor.
It makes no server, network, or model calls.

Use Zig 0.17.0 and separate baseline and candidate source directories. The baseline
for the recorded comparison is commit `8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb`.
The candidate uses the source hashes recorded beside its raw samples. Build both
binaries before running them so compilation does not overlap measured execution:

```sh
sh docs/engineering/cli-optimizations/cas-framing/reproduce.sh build \
  BASELINE_SOURCE CANDIDATE_SOURCE BUILD_DIR
sh docs/engineering/cli-optimizations/cas-framing/reproduce.sh run \
  BUILD_DIR OUTPUT_DIR
```

The build command copies runtime sources into `BUILD_DIR` and appends the harness
to those copies, leaving both source trees unchanged. It compiles each side
sequentially with `-j1 -O ReleaseFast`, applying the same optimization mode to
every imported module. The run command writes environment details, source hashes,
and complete baseline/candidate output into `OUTPUT_DIR`. Use an empty build
directory, and stop other benchmark/build work before running measurements.

Each side produces seven samples for newline-terminated inputs of 1 KiB, 64 KiB,
and 1 MiB, including the newline. Every sample starts with a fresh client and
checks that the returned record equals the input without its delimiter. The timed
interval includes framing and its buffer/output allocation; input construction,
comparison, and cleanup are outside it. All baseline samples run before candidate
samples, so order and thermal effects remain possible.

`reads` counts synthetic streaming read operations; `positional` counts rejected
positional probes. These are operation counts, not measured operating-system
syscalls. `allocations` counts allocation, resize, and remap attempts through the
repository's `CountingAllocator`, backed by `std.testing.allocator`.
`requested_bytes` is the sum of requested sizes, including resize/remap attempts;
it is neither peak nor retained memory. The counter overhead is present on both
sides. The smallest timings are especially sensitive to timer and allocator noise.

This isolates framing work. It excludes process startup, polling, JSON parsing,
server work, and actual pipe scheduling. The latency samples do not establish
end-to-end CAS speedup, service percentiles, or a production memory bound. Deadline,
EOF, queued-line, size-boundary, and allocation-failure behavior are checked by
the repository's JSONL core and CAS runtime/transport tests.

## Recorded observations

The [raw samples](raw/) were collected on an Apple M2 Pro with macOS 27.2 and
Zig 0.17.0. Each side passed all 21 record-equality checks. Other session benchmark
and build work was paused during measurement, but unrelated host activity remained.
These seven samples per size support a local mechanism comparison; the large
timing ratio must not be read as a whole-command speedup.

| Input including newline | Baseline median ms (min–max) | Candidate median ms (min–max) |
| --- | --- | --- |
| 1 KiB | 0.039042 (0.038792–0.042250) | 0.000292 (0.000125–0.008166) |
| 64 KiB | 42.657625 (42.379042–42.765000) | 0.032083 (0.023333–0.036375) |
| 1 MiB | 10,358.362708 (10,326.015291–11,459.946542) | 0.394041 (0.365709–0.480875) |

Counts below show baseline → candidate and were identical across the seven
samples except for the indicated baseline requested-byte range at 64 KiB.

| Input | Streaming reads | Rejected positional probes | Allocation attempts | Requested bytes |
| --- | --- | --- | --- | --- |
| 1 KiB | 1,024 → 1 | 1,024 → 0 | 5 → 2 | 3,139 → 7,295 |
| 64 KiB | 65,536 → 16 | 65,536 → 0 | 21 → 10 | 483,791–492,418 → 367,743 |
| 1 MiB | 1,048,576 → 256 | 1,048,576 → 0 | 35 → 24 | 8,753,992 → 8,528,767 |

The small input requests more bytes because the candidate reserves a chunk-sized
buffer. It still performs fewer allocation attempts. Larger frames remove both
per-byte reads and repeated whole-prefix scans. The startup-receipt reader also
uses the shared cursor, but this benchmark measures only the client message path.
