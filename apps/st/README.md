# st

Native Zig CLI for dependency-aware plan state in `.step/st-plan.jsonl`.

## Surface

`st` now covers both durable plan storage and execution metadata handoff for orchestration flows:

- `import-orchplan`
- `claim`
- `heartbeat`
- `set-runtime`
- `set-proof`
- `release`
- `reclaim-stale`
- `import-mesh-results`

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
zig build run-st -- import-orchplan --file .step/st-plan.jsonl --input .step/orchplan.yaml
zig build run-st -- claim --file .step/st-plan.jsonl --ids "cfg,ui" --executor teams --wave w1
zig build run-st -- set-runtime --file .step/st-plan.jsonl --id cfg --substrate spawn_agent --thread-id thread-cfg
zig build run-st -- set-proof --file .step/st-plan.jsonl --id cfg --proof-state pass --command "zig build test-st" --evidence-ref .step/proof.log
zig build run-st -- import-mesh-results --file .step/st-plan.jsonl --input .step/mesh-output.csv
zig build run-st -- emit-plan-sync --file .step/st-plan.jsonl
zig build run-st -- emit-update-plan --file .step/st-plan.jsonl # legacy Codex compatibility
```
