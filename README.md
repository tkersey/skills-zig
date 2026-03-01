# skills-zig monorepo

Monorepo for Zig CLIs with shared internal libraries and independent release streams.

## CLIs

- `seq` (session/memory mining)
- `lift` (`bench_stats`, `perf_report`)
- `cas` (`cas_smoke_check`, `cas_instance_runner`)
- `cron` (`cron`)
- `puff` (`puff`)
- `learnings` (`learnings`, `append_learning`)
- `mesh` (`mesh`)
- `st` (`st`)

No unified umbrella CLI is introduced. Binaries remain separate.

## Layout

- `apps/seq`
- `apps/lift`
- `apps/cas`
- `apps/cron`
- `apps/puff`
- `apps/learnings`
- `apps/mesh`
- `apps/st`
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
zig build build-cron -Doptimize=ReleaseFast
zig build build-puff -Doptimize=ReleaseFast
zig build build-learnings -Doptimize=ReleaseFast
zig build build-mesh -Doptimize=ReleaseFast
zig build build-st -Doptimize=ReleaseFast
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
- `apps/cron/VERSION`
- `apps/puff/VERSION`
- `apps/learnings/VERSION`
- `apps/mesh/VERSION`
- `apps/st/VERSION`

Independent tags trigger independent workflows, and each tag must match its app VERSION file:

- `seq-v*` -> `.github/workflows/release-seq.yml`
- `lift-v*` -> `.github/workflows/release-lift.yml`
- `cas-v*` -> `.github/workflows/release-cas.yml`
- `cron-v*` -> `.github/workflows/release-cron.yml`
- `puff-v*` -> `.github/workflows/release-puff.yml`
- `learnings-v*` -> `.github/workflows/release-learnings.yml`
- `mesh-v*` -> `.github/workflows/release-mesh.yml`
- `st-v*` -> `.github/workflows/release-st.yml`

Required tag forms:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `cron-v<version>` where `<version>` equals `apps/cron/VERSION`
- `puff-v<version>` where `<version>` equals `apps/puff/VERSION`
- `learnings-v<version>` where `<version>` equals `apps/learnings/VERSION`
- `mesh-v<version>` where `<version>` equals `apps/mesh/VERSION`
- `st-v<version>` where `<version>` equals `apps/st/VERSION`

Artifacts are published as:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Each release workflow verifies that both archives are present.

## Homebrew

Tap formulas are maintained in a separate tap repository. See `docs/release/README.md`.
