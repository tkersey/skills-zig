# Release Automation

This monorepo uses independent GitHub Actions release workflows per CLI:

- `seq`: `.github/workflows/release-seq.yml` on tag `seq-v*`
- `lift`: `.github/workflows/release-lift.yml` on tag `lift-v*`
- `cas`: `.github/workflows/release-cas.yml` on tag `cas-v*`
- `ledger`: `.github/workflows/release-ledger.yml` on tag `ledger-v*`
- `memory-note`: `.github/workflows/release-memory-note.yml` on tag `memory-note-v*`

Codex automation is part of CAS 0.4 and is invoked through `cas automation`.
It uses the CAS build, version, tag, release archives, and tap formula; there is
no standalone release identity or compatibility alias.

Per-app VERSION files:

- `apps/seq/VERSION`
- `apps/lift/VERSION`
- `apps/cas/VERSION`
- `apps/ledger/VERSION`
- `apps/memory-note/VERSION`

Release contract:

1. If a PR changes a release-relevant CLI surface, it must also bump that CLI's `VERSION` file.
2. Release-relevant surfaces are conservative:
   - `apps/<cli>/**` except the per-app `README.md` counts for that CLI.
   - `build.zig` and `build.zig.zon` changes are classified by their affected app or shared-library context; ambiguous changes fail closed to every shipped CLI.
   - broad shared shipped surfaces (`libs/core/**`) count for every shipped CLI.
   - `libs/definition_core/**` and `libs/definition_compat/**` count for their shipped consumers: `seq`, `cas`, and `ledger`.
   - `libs/durable_store/**` and `libs/jsonl_core/**` count for their shipped consumers: `seq`, `cas`, `ledger`, and `memory-note`.
   - `libs/trace_core/**` counts for its shipped consumers: `seq` and `cas`.
   - `libs/cas_runtime/**` counts for CAS, its sole shipped consumer.
   - `.github/workflows/release-<cli>.yml` counts for that CLI's packaged artifact contract.
   Durable-store changes that alter lease locks, fencing counters, CAS writes, transaction recovery, or semantic concurrency errors must be treated as release-relevant for every shipped consumer whose command behavior depends on those paths.
3. When those `VERSION` bumps land on `main`, `.github/workflows/auto-release.yml` dispatches the matching release workflows. For Seq, Auto Release dispatches `release-seq.yml` from `main` with the exact merged `commit_sha`; the workflow qualifies both release targets before its dependent publish job creates a missing tag. Other CLI workflows retain tag-first dispatch. A manual release dispatch normally selects the existing release tag as its workflow ref and passes the same `tag_name`, for example `gh workflow run release-<cli>.yml --ref <tag> -f tag_name=<tag>`. A deliberate tagless Seq dispatch must also pass the exact commit with `-f commit_sha=<sha>`.
4. Do not treat a local `./zig-out/bin` binary as release closure for a shipped CLI. Closure requires a tagged release, tap formula update, Homebrew audit/test proof, and installed binary version proof.
5. Generic release builds must declare their target architecture and use Zig's baseline CPU. Build-time dependencies carried by a release binary must be content-addressed rather than inherited from the build runner. Seq's release workflow must also initialize Zig 0.16's ZIP package-cache directory before a clean-runner fetch.

Release tags must match file versions:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `ledger-v<version>` where `<version>` equals `apps/ledger/VERSION`
- `memory-note-v<version>` where `<version>` equals `apps/memory-note/VERSION`

Each workflow publishes two release archives for its independently versioned CLI. CAS neither bundles nor executes Ledger; caller workflows validate inquiry carriers before handing them to CAS.

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Examples:

- `seq-v1.2.3-linux-x86_64.tar.gz`
- `seq-v1.2.3-darwin-arm64.tar.gz`
- `lift-v1.2.3-linux-x86_64.tar.gz`
- `lift-v1.2.3-darwin-arm64.tar.gz`
- `cas-v1.2.3-linux-x86_64.tar.gz`
- `cas-v1.2.3-darwin-arm64.tar.gz`
- `ledger-v1.2.3-linux-x86_64.tar.gz`
- `ledger-v1.2.3-darwin-arm64.tar.gz`
- `memory-note-v1.2.3-linux-x86_64.tar.gz`
- `memory-note-v1.2.3-darwin-arm64.tar.gz`

## Homebrew Tap Handoff

Homebrew formula updates are intentionally handled in a separate tap repository.
This repo does not support installing its CLIs into user-global paths from source builds.
Build artifacts are only allowed under repo-local `zig-out/bin`; shipped installs must flow through a tagged release plus the tap formula update.
After a tagged release in this repo:

1. Copy the release asset URL and SHA256 for the relevant CLI archive.
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
