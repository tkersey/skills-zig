# CLI release discipline

- Do not deliver shipped CLI fixes as local-only `./zig-out/bin` builds.
- Any release-relevant change to a CLI surface must bump that CLI's `apps/<cli>/VERSION`.
- Any release-relevant shared change must bump every affected shipped CLI version.
- Closure for release-relevant CLI work requires the tagged GitHub release, tap formula update, Homebrew audit/test, and installed binary version proof.
- Treat local builds as development proof only; the supported install path for shipped CLIs is Homebrew/tap.
- Follow `docs/release/README.md` for the current release and tap handoff steps.
