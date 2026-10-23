# Memory-note inventory comparison

Build the baseline and candidate with Zig 0.17.0 and identical ReleaseFast settings.
The baseline for this change is commit `8e470a24b533dba479f39f7ae3cc7f07b5fc5aeb`.
In each checkout:

```sh
zig build build-memory-note -Doptimize=fast -j1
```

Run on a quiet machine, supplying the two development binaries:

```sh
uv run --no-project benchmark.py \
  --baseline /path/to/baseline/zig-out/bin/memory-note \
  --candidate /path/to/candidate/zig-out/bin/memory-note \
  --output results.json
```

The standard-library-only helper creates temporary synthetic homes and removes them
when finished. It performs no account, personal-memory, model, or network access.
It covers 32, 1,024, and 4,096 notes, with seven alternating process samples per
binary for list, show, duplicate append, fresh append, 128-KiB fresh append, and
migration preview. All append and migration operations use dry-run mode.

Every paired output must agree. Fresh admissions validate generated identifiers
and timestamp-derived filenames before normalizing their clock fields. Synthetic
root paths are normalized in recorded hashes. Other output is compared unchanged.
The report records binary hashes, versions, platform, and every raw timing sample.

These are warm-filesystem, whole-process measurements, including startup and
output capture. They do not estimate service tail latency or cold-storage behavior.
Fresh-append cases check the counting serializer's potential extra-pass cost.
