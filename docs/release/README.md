# Release Automation

This monorepo uses independent GitHub Actions release workflows per CLI:

- `seq`: `.github/workflows/release-seq.yml` on tag `seq-v*`
- `lift`: `.github/workflows/release-lift.yml` on tag `lift-v*`
- `ledger`: `.github/workflows/release-ledger.yml` on tag `ledger-v*`
- `memory-note`: `.github/workflows/release-memory-note.yml` on tag `memory-note-v*`
- `siwc`: `.github/workflows/release-siwc.yml` on tag `siwc-v*`

CAS is retired; it has no current build, VERSION, tag dispatcher, or release
workflow. Existing releases and local automation data are not deleted. See
[retirement migration](#cli-retirement-migration) for existing installations.

Per-app VERSION files:

- `apps/seq/VERSION`
- `apps/lift/VERSION`
- `apps/ledger/VERSION`
- `apps/memory-note/VERSION`
- `apps/siwc/VERSION`

Release contract:

1. If a PR changes a release-relevant CLI surface, it must also bump that CLI's `VERSION` file.
2. Release-relevant surfaces are conservative:
   - `apps/<cli>/**` except the per-app `README.md` counts for that CLI.
   - `build/apps/<cli>.zig` owns each app's root-build assembly and counts for that CLI.
   - Root `build.zig`, `build.zig.zon`, shared `build/support.zig`, and unknown `build/**` or `libs/**` paths count for every shipped CLI. Classification uses both sides of renamed or moved paths; root-build diff text is never interpreted as ownership.
   - broad shared shipped surfaces (`libs/core/**`) count for every shipped CLI.
   - shared install admission (`apps/seq/build_support.zig` and `tools/install_guard.zig`) counts for every shipped CLI, regardless of its source directory.
   - `libs/definition_core/**` and `libs/definition_compat/**` count for their shipped consumers: `seq` and `ledger`.
   - `libs/durable_store/**` and `libs/jsonl_core/**` count for their shipped consumers: `seq`, `ledger`, `memory-note`, and `siwc`.
   - `libs/trace_core/**` counts for its shipped consumers: `seq`.
   - `libs/siwc/**` counts for SIWC, its sole shipped consumer.
   - `.github/workflows/release-<cli>.yml` counts for that CLI's packaged artifact contract.
   - `.github/scripts/release_artifacts.py` and its archive/ownership regression tests count for all five CLIs.
   Durable-store changes that alter lease locks, fencing counters, CAS writes, transaction recovery, or semantic concurrency errors must be treated as release-relevant for every shipped consumer whose command behavior depends on those paths.
3. When those `VERSION` bumps land on `main`, `.github/workflows/auto-release.yml` dispatches the matching release workflows. For Seq, Auto Release dispatches `release-seq.yml` from `main` with the exact merged `commit_sha`; all three release targets and the exact archive set must qualify before its dependent publish job creates a missing tag. Other CLI workflows retain tag-first dispatch. A manual release dispatch normally selects the existing release tag as its workflow ref and passes the same `tag_name`, for example `gh workflow run release-<cli>.yml --ref <tag> -f tag_name=<tag>`. A deliberate tagless Seq dispatch must also pass the exact commit with `-f commit_sha=<sha>`.
4. Do not treat a local `./zig-out/bin` binary as release closure for a shipped CLI. Closure requires a tagged release and installed binary version proof. Unix Homebrew distribution additionally requires a tap formula update and Homebrew audit/test proof; Windows distribution requires the qualified ZIP and extracted executable proof described below.
5. Generic release builds must declare their target architecture and use Zig's baseline CPU. Build-time dependencies carried by a release binary must be content-addressed rather than inherited from the build runner. Direct Zig downloads must match the pinned archive checksum; setup-zig verifies the upstream signature. Clean runners prepare the package-cache directory before fetching dependencies. macOS artifacts require macOS 15 and use the explicit `aarch64-macos.15.0` target; tap formulas must declare the same minimum.

Root build assembly creates the shared modules once through `build/support.zig` and
passes them to the five `build/apps/<cli>.zig` owners. The root package includes the
whole `build/` directory; PR CI, Auto Release, cache inputs, and lint cover it.
The install guard remains in `apps/seq/build_support.zig` so both root and standalone
Seq builds share the same make-time admission. Releases build the repository checkout
and package the surviving executable names without a CAS sibling layout.

`affected` selects release-relevant applications, `ci-affected` additionally selects
all applications for CI/classifier changes, and `version-changed` selects only edited
application VERSION files. Documentation-only and established tool-only changes
retain their existing treatment. Root/package edits are intentionally conservative,
even when their text mentions only one product or a retired application.

Release tags must match file versions:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `ledger-v<version>` where `<version>` equals `apps/ledger/VERSION`
- `memory-note-v<version>` where `<version>` equals `apps/memory-note/VERSION`
- `siwc-v<version>` where `<version>` equals `apps/siwc/VERSION`

Each workflow requires exactly three release archives for its independently
versioned CLI before publication:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`
- `<tag>-windows-x86_64.zip`

Unix archives contain only the executable named after the CLI, except Lift's
`lift-bench-stats`. Windows ZIPs contain only the corresponding `.exe`, including
`lift-bench-stats.exe` for Lift. PDBs, import libraries, companion DLLs, nested
payload paths, symlinks, and duplicate members are not release payloads.
The publisher checks exact names and archive contents, not just an archive count.
Missing Windows qualification cannot silently produce a two-platform release.

## Native Windows Qualification

The Windows target is `x86_64-windows-gnu` with `-Dcpu=baseline`, executed on the
`windows-2025` runner. Workflow commands select Git Bash explicitly; the shipped
executable is native Windows, not a WSL or MSYS build. PR CI selects Windows apps
from the same ownership classifier as the existing lanes. Each app has its own
setup-zig cache key, so concurrent apps do not compete to save one cache entry.

Both PR CI and the release matrices run the same command:

```bash
python .github/scripts/release_artifacts.py windows <cli>
# Releases additionally supply --tag "$RELEASE_TAG".
```

The helper runs the app tests in Debug and ReleaseSafe, then builds ReleaseFast.
Seq also runs its core and CLI smoke targets. The built Seq and Ledger binaries
run their command-surface gates; memory-note runs its CLI layout/migration script.
Every subprocess failure is fatal.
Only a successful native run may create the final release ZIP. Cross-compilation
alone is not qualification.

The helper admits one regular x86_64 PE32+ executable, packages it, verifies the
ZIP, and executes the extracted payload from a fresh directory containing spaces.
Its exact `--version` and successful `--help` are checked with `PATH` restricted
to Windows system directories, excluding Git Bash, Zig, and MinGW tools. This
prevents a runner-only DLL or executable on `PATH` from masking a broken release.
The PR uploads successful ZIPs as seven-day workflow artifacts, not GitHub releases.

All five native Windows lanes must succeed before treating Windows support as
implemented. A matrix row is not evidence that POSIX-specific storage, permission,
process, or command behavior has been ported. Failed tests must not be skipped or
credential/durability checks weakened to produce a release archive.
This contract does not claim Windows ARM64 support, an MSI/winget installer, or
Authenticode signing. Existing Unix archive names and Homebrew layouts are unchanged.

SIWC qualifies its offline authentication and command tests in Debug and
ReleaseSafe on every release platform before producing archives. Its Linux target
is `x86_64-linux-musl`; macOS uses `aarch64-macos.15.0`; Windows uses the target above.
The archives contain only `siwc` or `siwc.exe`, and qualification checks version
and help. No release or CI job uses a real ChatGPT account or performs paid inference.
The initial Homebrew formula is a separate tap handoff after the first release.

## Homebrew Tap Handoff

Homebrew formula updates are intentionally handled in a separate tap repository.
This repo does not support installing its CLIs into user-global paths from source builds.
Build artifacts are only allowed under repo-local `zig-out/bin`; Unix shipped installs
flow through a tagged release plus the tap formula update. Windows users extract the
qualified release ZIP rather than installing a Homebrew formula.
After a tagged release in this repo:

1. Copy the release asset URL and SHA256 for the relevant Unix CLI archive.
2. Open the separate tap repo and update only that CLI formula.
3. Ship the formula change from the tap repo as a separate PR/release step.

This keeps binary publishing (this repo) decoupled from tap formula maintenance (tap repo).

## Queue Triage (Tag Pushes)

When a release tag is pushed and no new run appears in a default `gh run list` view,
do not assume the workflow failed to trigger.

Use explicit queue checks first:

```bash
gh run list --workflow release-seq.yml --status queued --limit 20
gh run list --workflow release-ledger.yml --status queued --limit 20
gh run view <run-id> --json status,jobs,headBranch,createdAt
```

If runs are queued for several minutes with no steps started, check GitHub service health:

```bash
curl -fsSL https://www.githubstatus.com/api/v2/status.json
curl -fsSL https://www.githubstatus.com/api/v2/components.json \
  | jq -r '.components[] | select(.name=="Actions") | [.name,.status,.updated_at] | @tsv'
```

## Outage Fallback (Manual Publish)

An Actions outage does not relax native qualification or the exact asset contract.
Manual publication requires successful evidence for the same commit on all three
platforms; otherwise leave the release unpublished.

1. On clean checkouts of the exact release tag, run the affected CLI's build and test lanes and retain successful command output with the tag commit SHA. Run the shared Windows helper on native Windows; a Unix cross-build does not replace it.
2. Collect `<tag>-darwin-arm64.tar.gz`, `<tag>-linux-x86_64.tar.gz`, and `<tag>-windows-x86_64.zip` under `release-assets`.
3. From that checkout, require `python3 .github/scripts/release_artifacts.py verify-set <cli> <tag> release-assets` to succeed before running `gh release create <tag> <asset1> <asset2> <asset3> --verify-tag`.
4. Update `homebrew-tap` formula version + SHA256 from the published Unix assets.
5. Prove Unix end-to-end with:
   - `brew audit --strict tkersey/tap/<cli>`
   - `brew upgrade --formula tkersey/tap/<cli>`
   - `brew test tkersey/tap/<cli>`
   - `<cli> --version`
6. Retain the Windows helper's extracted ZIP version/help proof; verify the installed Windows executable's version on the destination host.

## CLI retirement migration

### CAS

CAS is retired after the native-Codex skill migration in
[dotfiles #387](https://github.com/tkersey/dotfiles/pull/387). This source removal
eliminates its executables, runtime library, benchmarks, packaging, and release
selection. It does not install a compatibility shim, mutate Codex data, stop a
scheduler, uninstall a package, or remove historical releases and evidence.
The root-build change follows the existing conservative release rule: all five
surviving CLIs receive VERSION bumps and normal release qualification.

Before uninstalling an existing CAS package, inspect the actual local scheduler
and external callers. In particular, the old launchd job can invoke
`cas automation run-due` or the `cas_automation` sibling. The default label was
`com.openai.codex.automation-runner`; custom labels and independent installations
are possible. A repository scan does not establish absence of host dependencies.
Migrate needed schedules or deliberately retire them with the owner's authority
before removing their executable. Native Codex execution is not an automatic
replacement for the old automation store/scheduler semantics.

Preserve `~/.codex/sqlite/codex-dev.db`, `~/.codex/automations/`, run history,
memories, logs, and historical review evidence. Do not rewrite these into a new
store or delete them during package cleanup. Unresolved scheduler inventory is
a blocker to local uninstallation, not permission to assume no jobs exist.

The linked Homebrew tap change removes `Formula/cas.rb` and its installation
listing. It does not uninstall existing kegs. Once dependencies are resolved,
use Homebrew's supported uninstall operation for the verified owned package;
check `brew list --versions`, `brew list --pinned`, and command resolution first.
Do not unpin automatically, delete same-name files manually, or remove an
independently installed tool. No local uninstallation is implied by merging
these repository PRs.

Historical CAS performance capsules keep their original bytes. Their removed
cases are not active performance workloads; use the recorded original revision
and toolchain for historical readback/reproduction. Compare-and-swap operations
in the surviving generic storage libraries are unrelated to the retired CLI.

### Earlier TypeSafe and Lift retirements

TypeSafe is retired. Lift ships only `bench_stats`; `perf_report` is removed.
The Lift parser benchmark remains `zig build bench-lift-bench-stats`, with no
installed or packaged benchmark executable. Existing data and historical
release evidence remain unchanged. Unix Lift archives contain only
`lift-bench-stats`, renamed to `bench_stats` by the formula; use the Lift archive
verifier before publication. Windows ZIPs contain `lift-bench-stats.exe`.

Upgrade only installed surviving formulas, without automatically unpinning any:

```bash
brew update
brew upgrade --formula tkersey/tap/seq tkersey/tap/lift tkersey/tap/ledger tkersey/tap/memory-note tkersey/tap/siwc
# Only if the owned TypeSafe package is installed:
brew uninstall --formula tkersey/tap/typesafe
```

If a removed formula name cannot be resolved, inspect the existing keg's recorded
identity and use Homebrew's supported uninstall path for that installation.
Verify actual prefixes, versions, and executable inventories; old unlinked kegs
are not active commands. Independent copies and alternate prefixes remain
separate observations.
