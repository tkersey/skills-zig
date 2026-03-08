# parse-arch-zig-cli

Native Zig CLI for repository architecture signal collection.

## Scope
- `collect`: emit the static architecture evidence JSON consumed by the `parse` skill
- `eval`: run the fixture-based regression suite
- `doctor`: verify suite path, repo path, and collector readiness

## Runtime contract
- No Python runtime or shell delegation in shipped command paths.
- `collect` preserves the current `parse` collector flag surface: `repo_path`, repeatable `--focus-path`, and `--read-limit`.
- `eval` owns the YAML fixture suite under `apps/parse-arch/references/eval`.
- `doctor` is fail-closed and exits non-zero when suite loading or collector readiness fails.

## Build
```bash
zig build build-parse-arch -Doptimize=ReleaseFast
zig build test-parse-arch
zig build run-parse-arch -- --help
zig build run-parse-arch -- eval --suite apps/parse-arch/references/eval/suite.yaml
```
