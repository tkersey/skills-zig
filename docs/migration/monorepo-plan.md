# Split-repo to monorepo migration notes

## Goal

Consolidate `seq`, `lift`, and `cas` into one source monorepo to share Zig internals while preserving independent binary releases.

## Mapped paths

- `seq/` -> `apps/seq/`
- `lift/` -> `apps/lift/`
- `cas/` -> `apps/cas/`
- shared helpers -> `libs/core/src/`

## Shared helpers introduced

- `libs/core/src/json_helpers.zig`
- `libs/core/src/io_helpers.zig`
- `libs/core/src/path_helpers.zig`

## Import boundary rule

- For code that depends on shared libraries, avoid deep relative imports from script entrypoints.
- Use named module imports (for example `@import("core_io")`) and wire them in `build.zig` imports per executable.
- Build workflows should call `zig build` steps that provide the module graph instead of raw `zig build-exe` file invocations.

## Independent release guarantees

- Separate tag namespaces (`seq-v*`, `lift-v*`, `cas-v*`)
- Separate release workflows
- Separate artifacts per CLI
- Separate tap maintenance flow

## Validation baseline

- `zig build build-seq -Doptimize=ReleaseFast`
- `zig build build-lift -Doptimize=ReleaseFast`
- `zig build build-cas -Doptimize=ReleaseFast`
- `cd apps/seq && zig build test`
- workflow YAML parse check with `PyYAML`
