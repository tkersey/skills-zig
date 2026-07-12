# skills-zig monorepo

Monorepo for Zig CLIs with shared internal libraries and independent release streams.

## CLIs

- `seq` (session/memory mining)
- `lift` (`bench_stats`, `perf_report`)
- `cas` (`cas_smoke_check`, `cas_instance_runner`, `cas_review_session`)
- `cron` (`cron`)
- `ledger` (`ledger`, including `ledger --source actuation`, source-memory namespaces, and pure `ledger validate` governance checks)
- `memory-note` (`memory-note`)

No unified umbrella CLI is introduced. Binaries remain separate.

## Layout

- `apps/seq`
- `apps/lift`
- `apps/cas`
- `apps/cron`
- `apps/learnings` (ledger-owned internal learning source)
- `apps/synesthesia` (ledger-owned internal Synesthesia source)
- `apps/ledger` (including the internal actuation kernel and stateless governance validators)
- `apps/memory-note`
- `libs/core`
- `libs/durable_store`
- `.github/workflows`
- `docs/release`

## Shared Libraries

`libs/durable_store` provides the backend-neutral `EventStore` contract for stateful Ledger sources. Migrated callers observe logical records, opaque revisions, compare-and-append receipts, stable store identities, and exclusive sessions for effectful transitions; they do not parse lines, manage storage locks, or choose a storage format. `PersistentEventStore` is the stable construction surface. Its current compatibility adapter stores JSONL at the established paths, while `MemoryEventStore` proves the same caller contract without a filesystem. Replacing the persistent adapter therefore changes the storage boundary, not migrated Ledger source logic or CLI behavior.

Legacy file helpers remain available for explicit import, export, repair, and unrelated single-file workflows. Coordinated multi-record mutation still uses lease, fencing, CAS, snapshot, and DTX-v1 transaction APIs.

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
zig build perf-compare-local -- --target cron
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
- `apps/ledger/VERSION`
- `apps/memory-note/VERSION`

PRs that touch release-relevant CLI surfaces must bump the corresponding `VERSION` file.
The check is conservative: app-local changes count for that app, `apps/learnings/**` and `apps/synesthesia/**` count for `ledger`, broad shared shipped surfaces such as `build.zig`, `build.zig.zon`, and `libs/core/**` count for every shipped CLI, and `libs/durable_store/**` counts for its shipped consumers.
Do not close release-relevant CLI work with a local `./zig-out/bin` binary alone.
Release closure means the changed CLI has a tagged GitHub release, the tap formula has been updated, Homebrew audit/test have passed, and the installed Homebrew binary reports the expected version.

Independent tags trigger independent workflows, and each tag must match its app VERSION file:

- `seq-v*` -> `.github/workflows/release-seq.yml`
- `lift-v*` -> `.github/workflows/release-lift.yml`
- `cas-v*` -> `.github/workflows/release-cas.yml`
- `cron-v*` -> `.github/workflows/release-cron.yml`
- `ledger-v*` -> `.github/workflows/release-ledger.yml`
- `memory-note-v*` -> `.github/workflows/release-memory-note.yml`

Pushes to `main` auto-create any missing release tags for changed `VERSION` files and dispatch the matching release workflow.
Manual tag pushes still work, but they are no longer the only path.

Required tag forms:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `cron-v<version>` where `<version>` equals `apps/cron/VERSION`
- `ledger-v<version>` where `<version>` equals `apps/ledger/VERSION`
- `memory-note-v<version>` where `<version>` equals `apps/memory-note/VERSION`

Artifacts are published as:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Each release workflow verifies that both archives are present.

## Homebrew

Tap formulas are maintained in a separate tap repository. See `docs/release/README.md`.
Homebrew/tap is the only supported install path for shipped CLIs.
Repo builds are development-only and must stay under `./zig-out/bin`; this build graph now rejects redirected installs via `--prefix`, `--prefix-exe-dir`, or `DESTDIR`.
