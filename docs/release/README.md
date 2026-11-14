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
   Durable-store changes that alter lease locks, fencing counters, CAS writes, transaction recovery, or semantic concurrency errors must be treated as release-relevant for every shipped consumer whose command behavior depends on those paths.
3. When those `VERSION` bumps land on `main`, `.github/workflows/auto-release.yml` dispatches the matching release workflows. For Seq, Auto Release dispatches `release-seq.yml` from `main` with the exact merged `commit_sha`; the workflow qualifies both release targets before its dependent publish job creates a missing tag. Other CLI workflows retain tag-first dispatch. A manual release dispatch normally selects the existing release tag as its workflow ref and passes the same `tag_name`, for example `gh workflow run release-<cli>.yml --ref <tag> -f tag_name=<tag>`. A deliberate tagless Seq dispatch must also pass the exact commit with `-f commit_sha=<sha>`.
4. Do not treat a local `./zig-out/bin` binary as release closure for a shipped CLI. Closure requires a tagged release, tap formula update, Homebrew audit/test proof, and installed binary version proof.
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

Each workflow publishes two release archives for its independently versioned CLI.

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Examples:

- `seq-v1.2.3-linux-x86_64.tar.gz`
- `seq-v1.2.3-darwin-arm64.tar.gz`
- `lift-v1.2.3-linux-x86_64.tar.gz`
- `lift-v1.2.3-darwin-arm64.tar.gz`
- `ledger-v1.2.3-linux-x86_64.tar.gz`
- `ledger-v1.2.3-darwin-arm64.tar.gz`
- `memory-note-v1.2.3-linux-x86_64.tar.gz`
- `memory-note-v1.2.3-darwin-arm64.tar.gz`
- `siwc-v1.2.3-linux-x86_64.tar.gz`
- `siwc-v1.2.3-darwin-arm64.tar.gz`

SIWC qualifies its offline authentication and command tests in Debug and
ReleaseSafe on both platforms before producing release archives. Its Linux
target is `x86_64-linux-musl`; macOS uses `aarch64-macos.15.0`. Each archive
contains only `siwc`, and qualification verifies its version and help surface.
No release or CI job uses a real ChatGPT account or performs paid inference.
The initial Homebrew formula is a separate tap handoff after the first release.

## Homebrew Tap Handoff

Homebrew formula updates are intentionally handled in a separate tap repository.
This repo does not support installing its CLIs into user-global paths from source builds.
Build artifacts are only allowed under repo-local `zig-out/bin`; shipped installs must flow through a tagged release plus the tap formula update.
The `Release ledger` publish job explicitly dispatches `Update Ledger tap` on
`main` after both platform archives have been published. The handoff carries the
exact release tag and commit; dispatch failure fails the publishing job instead
of leaving an unobserved completion-event handoff. The tap workflow verifies the
tag against the commit's VERSION and tag target, downloads both archives, and
checks their SHA256 digests against GitHub's release metadata. It changes only
the version and platform checksums in `Formula/ledger.rb`, then opens or updates
a version-specific PR in `tkersey/homebrew-tap`. Older releases cannot downgrade
the formula already on the tap's main branch.

Ledger updates automatically squash-merge only after verifying the exact PR head,
repository/branch, sole changed file, and formula bytes against the verified
release. An active tap ruleset without bypass actors must require both
`test-bot (macos-latest)` and `test-bot (ubuntu-latest)` from GitHub Actions
(app ID 15368) and resolved review conversations. Active change requests or review
requests block the merge. The job waits up to eight minutes for both checks on the
verified head, revalidates, then uses an exact-head merge guard. It does not arm
GitHub auto-merge for unverified successor commits. GitHub also enforces the
required checks. Manual retries use the same verification and merge path.
Repo settings are configured through GitHub. The workflow verifies the effective
status-check and review-thread requirements before merging.

The `Update Seq tap` workflow runs after a successful `Release seq` workflow.
It identifies the release tag from the run's two platform archive artifacts,
then verifies that both published archives match those artifacts byte for byte
and match GitHub's SHA256 digests. This supports tagless Seq dispatches whose
explicit build commit differs from the workflow's `main` commit. It opens or
updates a version-specific PR changing only `Formula/seq.rb`'s version and
platform checksums, with the same downgrade protection and tap CI requirements.
Both workflows use `.github/homebrew-tap/prepare.cjs`.

One-time setup: add the Actions secret `HOMEBREW_TAP_TOKEN` to this repository.
Use a fine-grained personal access token scoped only to
`tkersey/homebrew-tap`, with **Contents: read and write** and
**Pull requests: read and write**. The tap credential allows the resulting PR
to trigger its normal CI. A missing credential fails the tap workflow without
changing the already-published release.

The tap workflows must be on this repository's default branch for their
automatic handoffs. To retry a published release without rebuilding it, dispatch
`Update Ledger tap` on `main` with `tag_name=ledger-v<VERSION>`, or
`Update Seq tap` with `tag_name=seq-v<VERSION>`. Manual retries
also verify both published assets and refuse draft or prerelease releases.

For other CLIs, or a manual fallback:

1. Copy the release asset URL and SHA256 for the relevant CLI archive.
2. Open the separate tap repo and update only that CLI formula.
3. Ship the formula change from the tap repo as a separate PR/release step.

Binary publishing and tap PR maintenance remain separate workflows.

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

If GitHub Actions is degraded/outage and tag runs remain queued, publish manually so tap
propagation is not blocked:

1. On a clean checkout of the exact release tag, run the affected CLI's build and test lanes and retain the successful command output with the tag commit SHA.
2. Build and package the exact two release archives for the CLI:
   `<tag>-darwin-arm64.tar.gz` and `<tag>-linux-x86_64.tar.gz`.
3. Create the release directly on the existing tag:
   - `gh release create <tag> <asset1> <asset2> --verify-tag`
4. Update `homebrew-tap` formula version + SHA256 from the published assets.
5. Prove end-to-end with:
   - `brew audit --strict tkersey/tap/<cli>`
   - `brew upgrade --formula tkersey/tap/<cli>`
   - `brew test tkersey/tap/<cli>`
   - `<cli> --version`

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
release evidence remain unchanged. Lift archives contain only
`lift-bench-stats`, renamed to `bench_stats` by the formula; use the Lift archive
verifier before publication.

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
