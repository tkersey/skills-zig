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

Public contract note: `st` is the required public OrchPlan handoff for orchestration execution; do not document a separate same-turn non-`st` mode.

## Build

```bash
zig build build-st -Doptimize=ReleaseFast
```

## Run

```bash
zig build build-st -Doptimize=ReleaseFast
./zig-out/bin/st --help
```

## Example

```bash
./zig-out/bin/st add --file .step/st-plan.jsonl --step "Reproduce issue" --priority high
./zig-out/bin/st set-priority --file .step/st-plan.jsonl --id st-001 --priority medium
./zig-out/bin/st import-orchplan --file .step/st-plan.jsonl --input .step/orchplan.yaml
./zig-out/bin/st claim --file .step/st-plan.jsonl --wave w1 --executor teams
./zig-out/bin/st set-runtime --file .step/st-plan.jsonl --id cfg --substrate spawn_agent --thread-id thread-cfg
./zig-out/bin/st set-proof --file .step/st-plan.jsonl --id cfg --proof-state pass --command "zig build test-st" --evidence-ref .step/proof.log
./zig-out/bin/st import-mesh-results --file .step/st-plan.jsonl --input .step/mesh-output.csv
./zig-out/bin/st emit-plan-sync --file .step/st-plan.jsonl
./zig-out/bin/st emit-update-plan --file .step/st-plan.jsonl # legacy Codex compatibility
```
