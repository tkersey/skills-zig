# skills-zig monorepo

Monorepo for Zig CLIs with shared internal libraries and independent release streams.

## CLIs

- `seq` (passive observation definitions over execution/session evidence)
- `lift` (`bench_stats`)
- `cas` (`cas_smoke_check`, `cas_instance_runner`, `cas_review_session`, and Codex automation)
- `ledger` (passive artifact definitions, validation, transactions, replay, and projections)
- `memory-note` (`memory-note`)
- `siwc` (Sign in with ChatGPT credentials and application launching)

The established five Homebrew formulas expose 14 executable names: one each for
Seq, Lift, Ledger, and memory-note, plus CAS and its nine functional siblings.
SIWC's initial tap formula follows its first tagged release. A clean root
`zig build` installs those names, `siwc`, and the local `perf_hub`, for 16 names
in `zig-out/bin`.
There is no umbrella `lift` executable.

TypeSafe and `perf_report` are retired; see [migration](docs/release/README.md#cli-retirement-migration)
for existing installations.
Codex automation is owned by CAS 0.4 and is invoked through `cas automation`;
it shares CAS's build, version, tag, release, and formula identity, with no
separate compatibility alias.

## Layout

- `apps/seq`
- `apps/lift`
- `apps/cas`
- `apps/ledger`
- `apps/memory-note`
- `apps/siwc`
- `libs/core`
- `libs/definition_core`
- `libs/durable_store`
- `libs/trace_core`
- `libs/siwc`
- `.github/workflows`
- `docs/release`

## Shared Libraries

`libs/definition_core` owns bounded passive-definition closure loading,
canonical JSON, closure digests, parameters, cache headers, and shared result
metadata. `libs/trace_core` owns physical execution-trace normalization.
`libs/durable_store` owns bounded custody, revision, and atomic store mechanics.
None of these shared libraries contains skill or workflow semantics.

`libs/siwc` owns ChatGPT sign-in, application/account registrations, protected
credentials, and renewable sessions. The root package exports the `siwc` module
for native embedding. The [SIWC CLI](apps/siwc/README.md) uses the same owner for
login, credential acquisition, and launching compatible Responses applications.

## Build

Use Zig **0.17.0**. Shipped macOS binaries require macOS **15 or newer**;
release builds explicitly target `aarch64-macos.15.0` and the baseline CPU.
Linux release targets retain their existing ABI, including static musl for CAS.

```bash
zig build -Doptimize=fast
```

The standard optimization modes are `debug`, `safe`, `fast`, and `small`.
For the migration rationale and compatibility checks, see
[Zig 0.17 migration](docs/engineering/ZIG_017.md).

Targeted build steps:

```bash
zig build build-seq -Doptimize=fast
zig build build-lift -Doptimize=fast
zig build build-cas -Doptimize=fast
zig build build-ledger -Doptimize=fast
zig build build-memory-note -Doptimize=fast
zig build build-siwc -Doptimize=fast
```

Run helpers:

```bash
zig build -Doptimize=fast
./zig-out/bin/seq --help
./zig-out/bin/bench_stats --help
./zig-out/bin/cas_smoke_check --help
./zig-out/bin/cas automation --help
./zig-out/bin/siwc --help
```

SIWC's offline authentication and command tests run with `zig build test-siwc`.
Its PR and release qualification run both Debug and ReleaseSafe on Linux and
macOS; qualification uses synthetic credentials and does not sign in to an account.

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
PERF_EXPECT_BASE_SHA=<base-revision> \
PERF_EXPECT_CANDIDATE_SHA=<candidate-revision> \
  zig build perf-report-local
```

Content-addressed performance capsules live under the ignored
`.perf-local/<machine-id>/capsules/` root. A successful paired comparison
atomically updates `reports/current-capsule.json`, the non-authoritative
locator verified by `perf-report-local`. Interrupted runs leave that locator
incomplete; unmatched targets preserve the prior locator.
Representative native qualification inputs remain beside the owning runtime.
The Lift parser and CAS budget-governor benchmarks remain development tools:

```bash
zig build bench-lift-bench-stats -Doptimize=fast -- --config /absolute/path/to/workload_config.json --artifact /absolute/path/to/result.json
zig build bench-cas-budget-governor -Doptimize=fast -- --config /absolute/path/to/workload_config.json --artifact /absolute/path/to/result.json
```

These targets create no benchmark install artifact. See the [Lift](apps/lift/README.md)
and [CAS](apps/cas/README.md#development-benchmark) guides for workloads and gates.
`perf-report-local` remains the existing `perf_hub report` entrypoint. Historical
capsules retain their original bytes and revisions. Capsules containing retired
utility cases may fail current registry-bound validation; inspect them with their
recorded original revision/toolchain where available.

## Release Model

Per-app VERSION files are the source of truth:

- `apps/seq/VERSION`
- `apps/lift/VERSION`
- `apps/cas/VERSION`
- `apps/ledger/VERSION`
- `apps/memory-note/VERSION`
- `apps/siwc/VERSION`

PRs that touch release-relevant CLI surfaces must bump the corresponding
`VERSION` file. The check is conservative: app-local changes count for that
app. Ledger stays independently classified because CAS neither bundles nor
executes it. `build/apps/<cli>.zig` owns each app's root-build assembly and counts for
that app. Root `build.zig`, `build.zig.zon`, shared build support, and unknown
`build/**` or `libs/**` paths count for every shipped CLI. Broad shared shipped
surfaces such as
`libs/core/**` count for every shipped CLI;
`libs/definition_core/**` and `libs/definition_compat/**` count for `seq`,
`cas`, and `ledger`;
`libs/durable_store/**` and `libs/jsonl_core/**` count for `seq`, `cas`,
`ledger`, `memory-note`, and `siwc`;
`libs/trace_core/**` counts for `seq` and `cas`; and
`libs/siwc/**` counts for `siwc`.
Do not close release-relevant CLI work with a local `./zig-out/bin` binary alone.
Release closure means the changed CLI has a tagged GitHub release, the tap formula has been updated, Homebrew audit/test have passed, and the installed Homebrew binary reports the expected version.

Independent tags trigger independent workflows, and each tag must match its app VERSION file:

- `seq-v*` -> `.github/workflows/release-seq.yml`
- `lift-v*` -> `.github/workflows/release-lift.yml`
- `cas-v*` -> `.github/workflows/release-cas.yml`
- `ledger-v*` -> `.github/workflows/release-ledger.yml`
- `memory-note-v*` -> `.github/workflows/release-memory-note.yml`
- `siwc-v*` -> `.github/workflows/release-siwc.yml`

Pushes to `main` auto-create any missing release tags for changed `VERSION` files and dispatch the matching release workflow.
Manual tag pushes still work, but they are no longer the only path.

Required tag forms:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `ledger-v<version>` where `<version>` equals `apps/ledger/VERSION`
- `memory-note-v<version>` where `<version>` equals `apps/memory-note/VERSION`
- `siwc-v<version>` where `<version>` equals `apps/siwc/VERSION`

Artifacts are published as:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Each release workflow verifies that both archives are present.

## Homebrew

Tap formulas are maintained in a separate tap repository. See `docs/release/README.md`.
Homebrew/tap is the only supported install path for shipped CLIs.
Repo builds are development-only and must stay under `./zig-out/bin`; this build graph now rejects redirected installs via `--prefix`, `--prefix-exe-dir`, or `DESTDIR`.
