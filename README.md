# skills-zig monorepo

Monorepo for Zig CLIs with shared internal libraries and independent release streams.

## CLIs

- `seq` (passive observation definitions over execution/session evidence)
- `lift` (`bench_stats`, `perf_report`)
- `cas` (`cas_smoke_check`, `cas_instance_runner`, `cas_review_session`)
- `cron` (`cron`)
- `ledger` (passive artifact definitions, validation, transactions, replay, and projections)
- `memory-note` (`memory-note`)
- `img` (pure-Zig document and source-code PNG rendering)

No unified umbrella CLI is introduced. Binaries remain separate.

## Layout

- `apps/seq`
- `apps/lift`
- `apps/cas`
- `apps/cron`
- `apps/ledger`
- `apps/memory-note`
- `apps/img`
- `libs/core`
- `libs/definition_core`
- `libs/durable_store`
- `libs/trace_core`
- `.github/workflows`
- `docs/release`

## Shared Libraries

`libs/definition_core` owns bounded passive-definition closure loading,
canonical JSON, closure digests, parameters, cache headers, and shared result
metadata. `libs/trace_core` owns physical execution-trace normalization.
`libs/durable_store` owns bounded custody, revision, and atomic store mechanics.
None of these shared libraries contains skill or workflow semantics.

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
zig build build-ledger -Doptimize=ReleaseFast
zig build build-memory-note -Doptimize=ReleaseFast
zig build build-img -Doptimize=ReleaseFast
```

Run helpers:

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/seq --help
./zig-out/bin/bench_stats --help
./zig-out/bin/cas_smoke_check --help
./zig-out/bin/img --help
```

## Local Perf

Local performance regression tracking is machine-local, intentionally not part of CI, and now fronts through the native Zig `perf_hub` control plane.

```bash
zig build perf-list-local
zig build perf-manifest-local
zig build perf-audit-local
zig build perf-doctor-local
PERF_SEQ_BASE_BINARY=/path/to/base/seq \
PERF_LEDGER_BASE_BINARY=/path/to/base/ledger \
PERF_SEQ_BINARY=/path/to/candidate/seq \
PERF_LEDGER_BINARY=/path/to/candidate/ledger \
PERF_EXPECT_BASE_SHA=<base-revision> \
PERF_EXPECT_CANDIDATE_SHA=<candidate-revision> \
PERF_ZIG_BINARY=/absolute/path/to/zig \
  zig build perf-compare-local -- --target cutover
zig build perf-report-local
```

Content-addressed performance capsules live under the ignored
`.perf-local/<machine-id>/capsules/` root. A successful paired comparison
atomically updates `reports/current-capsule.json`, the non-authoritative
locator verified by `perf-report-local`. Interrupted runs leave that locator
incomplete; unmatched targets preserve the prior locator.
Representative native qualification inputs remain beside the owning runtime.

## Release Model

Per-app VERSION files are the source of truth:

- `apps/seq/VERSION`
- `apps/lift/VERSION`
- `apps/cas/VERSION`
- `apps/cron/VERSION`
- `apps/ledger/VERSION`
- `apps/memory-note/VERSION`
- `apps/img/VERSION`

PRs that touch release-relevant CLI surfaces must bump the corresponding `VERSION` file.
The check is conservative: app-local changes count for that app; `build.zig`
and `build.zig.zon` changes are classified by their affected app or
shared-library context and fail closed to every shipped CLI when ownership is
ambiguous; broad shared shipped surfaces such as `libs/core/**` count for every shipped CLI;
`libs/definition_core/**` counts for `seq` and `ledger`;
`libs/durable_store/**` counts for `seq`, `cas`, `ledger`, and `memory-note`; and
`libs/trace_core/**` counts for `seq` and `cas`.
Do not close release-relevant CLI work with a local `./zig-out/bin` binary alone.
Release closure means the changed CLI has a tagged GitHub release, the tap formula has been updated, Homebrew audit/test have passed, and the installed Homebrew binary reports the expected version.

Independent tags trigger independent workflows, and each tag must match its app VERSION file:

- `seq-v*` -> `.github/workflows/release-seq.yml`
- `lift-v*` -> `.github/workflows/release-lift.yml`
- `cas-v*` -> `.github/workflows/release-cas.yml`
- `cron-v*` -> `.github/workflows/release-cron.yml`
- `ledger-v*` -> `.github/workflows/release-ledger.yml`
- `memory-note-v*` -> `.github/workflows/release-memory-note.yml`
- `img-v*` -> `.github/workflows/release-img.yml`

Pushes to `main` auto-create any missing release tags for changed `VERSION` files and dispatch the matching release workflow.
Manual tag pushes still work, but they are no longer the only path.

Required tag forms:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `cron-v<version>` where `<version>` equals `apps/cron/VERSION`
- `ledger-v<version>` where `<version>` equals `apps/ledger/VERSION`
- `memory-note-v<version>` where `<version>` equals `apps/memory-note/VERSION`
- `img-v<version>` where `<version>` equals `apps/img/VERSION` (`img-v0.1.0` for the initial release)

Artifacts are published as:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Each release workflow verifies that both archives are present.

## Homebrew

Tap formulas are maintained in a separate tap repository. See `docs/release/README.md`.
Homebrew/tap is the only supported install path for shipped CLIs.
Repo builds are development-only and must stay under `./zig-out/bin`; this build graph now rejects redirected installs via `--prefix`, `--prefix-exe-dir`, or `DESTDIR`.
