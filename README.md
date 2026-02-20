# skills-zig monorepo

Monorepo for Zig CLIs with shared internal libraries and independent release streams.

## CLIs

- `seq` (session/memory mining)
- `lift` (`bench_stats`, `perf_report`)
- `cas` (`cas_smoke_check`, `cas_instance_runner`)

No unified umbrella CLI is introduced. Binaries remain separate.

## Layout

- `apps/seq`
- `apps/lift`
- `apps/cas`
- `libs/core`
- `.github/workflows`
- `docs/release`

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Targeted build steps:

```bash
zig build build-seq -Doptimize=ReleaseFast
zig build build-lift -Doptimize=ReleaseFast
zig build build-cas -Doptimize=ReleaseFast
```

Run helpers:

```bash
zig build run-seq -- --help
zig build run-bench-stats
zig build run-cas-smoke-check
```

## Release Model

Per-app VERSION files are the source of truth:

- `apps/seq/VERSION`
- `apps/lift/VERSION`
- `apps/cas/VERSION`

Independent tags trigger independent workflows, and each tag must match its app VERSION file:

- `seq-v*` -> `.github/workflows/release-seq.yml`
- `lift-v*` -> `.github/workflows/release-lift.yml`
- `cas-v*` -> `.github/workflows/release-cas.yml`

Required tag forms:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`

Artifacts are published as `<tag>-linux-x86_64.tar.gz` (no `*-cli` prefix).

## Homebrew

Tap formulas are maintained in a separate tap repository. See `docs/release/README.md`.
