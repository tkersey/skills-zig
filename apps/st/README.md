# st

Native Zig CLI for dependency-aware plan state in `.step/st-plan.jsonl`.

## Build

```bash
zig build build-st -Doptimize=ReleaseFast
```

## Run

```bash
zig build run-st -- --help
```

## Example

```bash
zig build run-st -- add --file .step/st-plan.jsonl --step "Reproduce issue" --priority high
zig build run-st -- set-priority --file .step/st-plan.jsonl --id st-001 --priority medium
zig build run-st -- emit-plan-sync --file .step/st-plan.jsonl
zig build run-st -- emit-update-plan --file .step/st-plan.jsonl # legacy Codex compatibility
```
