# Release Automation

This monorepo uses independent GitHub Actions release workflows per CLI:

- `seq`: `.github/workflows/release-seq.yml` on tag `seq-v*`
- `lift`: `.github/workflows/release-lift.yml` on tag `lift-v*`
- `cas`: `.github/workflows/release-cas.yml` on tag `cas-v*`
- `cron`: `.github/workflows/release-cron.yml` on tag `cron-v*`
- `ledger`: `.github/workflows/release-ledger.yml` on tag `ledger-v*`
- `memory-note`: `.github/workflows/release-memory-note.yml` on tag `memory-note-v*`

Per-app VERSION files:

- `apps/seq/VERSION`
- `apps/lift/VERSION`
- `apps/cas/VERSION`
- `apps/cron/VERSION`
- `apps/ledger/VERSION`
- `apps/memory-note/VERSION`

Release contract:

1. If a PR changes a release-relevant CLI surface, it must also bump that CLI's `VERSION` file.
2. Release-relevant surfaces are conservative:
   - `apps/<cli>/**` except the per-app `README.md` counts for that CLI.
   - broad shared shipped surfaces (`build.zig`, `build.zig.zon`, `libs/core/**`) count for every shipped CLI.
   - `apps/learnings/**` and `apps/synesthesia/**` count for `ledger`; they are internal source modules, not shipped CLIs.
   - `libs/durable_store/**` counts for its shipped consumers: `ledger` and `memory-note`.
   - `.github/workflows/release-<cli>.yml` counts for that CLI's packaged artifact contract.
   Durable-store changes that alter lease locks, fencing counters, CAS writes, transaction recovery, or semantic concurrency errors must be treated as release-relevant for every shipped consumer whose command behavior depends on those paths.
3. When those `VERSION` bumps land on `main`, `.github/workflows/auto-release.yml` creates any missing tags and dispatches the matching release workflows automatically.
4. Do not treat a local `./zig-out/bin` binary as release closure for a shipped CLI. Closure requires a tagged release, tap formula update, Homebrew audit/test proof, and installed binary version proof.

Release tags must match file versions:

- `seq-v<version>` where `<version>` equals `apps/seq/VERSION`
- `lift-v<version>` where `<version>` equals `apps/lift/VERSION`
- `cas-v<version>` where `<version>` equals `apps/cas/VERSION`
- `cron-v<version>` where `<version>` equals `apps/cron/VERSION`
- `ledger-v<version>` where `<version>` equals `apps/ledger/VERSION`
- `memory-note-v<version>` where `<version>` equals `apps/memory-note/VERSION`

Each workflow builds only binaries from its own CLI path and publishes two release archives:

- `<tag>-linux-x86_64.tar.gz`
- `<tag>-darwin-arm64.tar.gz`

Examples:

- `seq-v1.2.3-linux-x86_64.tar.gz`
- `seq-v1.2.3-darwin-arm64.tar.gz`
- `lift-v1.2.3-linux-x86_64.tar.gz`
- `lift-v1.2.3-darwin-arm64.tar.gz`
- `cas-v1.2.3-linux-x86_64.tar.gz`
- `cas-v1.2.3-darwin-arm64.tar.gz`
- `cron-v1.2.3-linux-x86_64.tar.gz`
- `cron-v1.2.3-darwin-arm64.tar.gz`
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

1. Build and package the two release archives per CLI (`<tag>-darwin-arm64.tar.gz`, `<tag>-linux-x86_64.tar.gz`).
2. Create the release directly on the existing tag:
   - `gh release create <tag> <asset1> <asset2> --verify-tag`
3. Update `homebrew-tap` formula version + SHA256 from the published assets.
4. Prove end-to-end with:
   - `brew audit --strict tkersey/tap/<cli>`
   - `brew upgrade --formula tkersey/tap/<cli>`
   - `brew test tkersey/tap/<cli>`
   - `<cli> --version`
