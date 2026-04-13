# skills-zig monorepo

Monorepo for Zig CLIs with shared internal libraries and independent release streams.

## CLIs

- `seq` (session/memory mining)
- `lift` (`bench_stats`, `perf_report`)
- `cas` (`cas_smoke_check`, `cas_instance_runner`, `cas_review_session`)
- `cron` (`cron`)
- `puff` (`puff`)
- `learnings` (`learnings append` primary, `append_learning` compatibility)
- `mesh` (`mesh`)
- `st` (`st`)
- `parse-arch` (`parse-arch`)

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
- `apps/parse-arch`
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
zig build build-parse-arch -Doptimize=ReleaseFast
```

Run helpers:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/seq --help
./zig-out/bin/bench_stats --help
./zig-out/bin/cas_smoke_check --help
```

## Local Perf

Local performance regression tracking is machine-local, intentionally not part of CI, and now fronts through the native Zig `perf_hub` control plane.

```bash
zig build perf-list-local
zig build perf-manifest-local
zig build perf-audit-local
zig build perf-doctor-local
zig build perf-capture-local
zig build perf-compare-local
zig build perf-report-local
zig build perf-accept-local

# Optional filter by binary or case id substring.
zig build perf-capture-local -- --target seq
zig build perf-compare-local -- --target parse-arch
```

Authoritative baselines live under `.perf-local/<machine-id>/baselines/` and are ignored by git.
Accepted baseline snapshots and compare summaries are stored under the same machine-local root.
`perf-report-local` also writes `latest-report.json` and `cutover-status.json` under the machine-local reports directory.
Checked-in fixtures remain under app-local `perf/` directories.

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
- `apps/parse-arch/VERSION`

PRs that touch release-relevant CLI surfaces must bump the corresponding `VERSION` file.
The check is conservative: app-local changes count for that app, and shared shipped surfaces such as `build.zig`, `build.zig.zon`, and `libs/core/**` count for every shipped CLI.

Independent tags trigger independent workflows, and each tag must match its app VERSION file:

- `seq-v*` -> `.github/workflows/release-seq.yml`
- `lift-v*` -> `.github/workflows/release-lift.yml`
- `cas-v*` -> `.github/workflows/release-cas.yml`
- `cron-v*` -> `.github/workflows/release-cron.yml`
- `puff-v*` -> `.github/workflows/release-puff.yml`
- `learnings-v*` -> `.github/workflows/release-learnings.yml`
- `mesh-v*` -> `.github/workflows/release-mesh.yml`
- `st-v*` -> `.github/workflows/release-st.yml`
- `parse-arch-v*` -> `.github/workflows/release-parse-arch.yml`

Pushes to `main` auto-create any missing release tags for changed `VERSION` files and dispatch the matching release workflow.
Manual tag pushes still work, but they are no longer the only path.

Required tag forms:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `cron-v<version>` where `<version>` equals `apps/cron/VERSION`
- `puff-v<version>` where `<version>` equals `apps/puff/VERSION`
- `learnings-v<version>` where `<version>` equals `apps/learnings/VERSION`
- `mesh-v<version>` where `<version>` equals `apps/mesh/VERSION`
- `st-v<version>` where `<version>` equals `apps/st/VERSION`
- `parse-arch-v<version>` where `<version>` equals `apps/parse-arch/VERSION`

Artifacts are published as:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Each release workflow verifies that both archives are present.

## Homebrew

Tap formulas are maintained in a separate tap repository. See `docs/release/README.md`.
Homebrew/tap is the only supported install path for shipped CLIs.
Repo builds are development-only and must stay under `./zig-out/bin`; this build graph now rejects redirected installs via `--prefix`, `--prefix-exe-dir`, or `DESTDIR`.
