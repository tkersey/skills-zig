# parse-arch-zig-cli

Native Zig CLI for repository architecture signal collection.

## Scope
- `collect`: emit the static architecture evidence JSON consumed by the `parse` skill
- `eval`: run the fixture-based regression suite
- `doctor`: verify suite path, repo path, and collector readiness

## Runtime contract
- No Python runtime or shell delegation in shipped command paths.
- `collect` accepts a positional `repo_path` plus the observed compatibility aliases `--repo-path`, `--repo`, `--json`, and `--format json`.
- `collect` still uses repeatable `--focus-path` and `--read-limit`, and always emits JSON.
- `collect` is fail-closed when repo selectors are mixed in one invocation or when `--format` is given any non-`json` value.
- `eval` owns the YAML fixture suite under `apps/parse-arch/references/eval`.
- `doctor` is fail-closed and exits non-zero when suite loading or collector readiness fails.

## Collect examples
```bash
./zig-out/bin/parse-arch collect /path/to/repo
./zig-out/bin/parse-arch collect --repo-path /path/to/repo --focus-path src --focus-path test
./zig-out/bin/parse-arch collect --repo /path/to/repo --json
./zig-out/bin/parse-arch collect /path/to/repo --format json
```

## Build
```bash
zig build build-parse-arch -Doptimize=ReleaseFast
zig build test-parse-arch
./zig-out/bin/parse-arch --help
./zig-out/bin/parse-arch eval --suite apps/parse-arch/references/eval/suite.yaml
```
