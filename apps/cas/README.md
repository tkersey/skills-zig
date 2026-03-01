# cas-zig-cli

Zig CLI utilities extracted from dotfiles CAS skill.

## Files
- `scripts/budget_governor.zig`
- `scripts/cas_smoke_check.zig`
- `scripts/cas_instance_runner.zig`
- `scripts/cas_proxy_client.zig`

## API Examples

```bash
# Filter thread/list by title substring.
cas instance_runner \
  --cwd /path/to/workspace \
  --method thread/list \
  --params-json '{"cursor":null,"limit":10,"searchTerm":"rollback"}' \
  --json

# Unsubscribe a connection from a loaded thread.
cas instance_runner \
  --cwd /path/to/workspace \
  --method thread/unsubscribe \
  --params-json '{"threadId":"thr_123"}' \
  --json
```

## Validation

```bash
zig build build-cas -Doptimize=ReleaseFast
bash apps/cas/scripts/perf/budget_governor_gate.sh
zig build test-cas

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_json --dep core_io -Mroot=apps/cas/scripts/budget_governor.zig -Mcore_json=libs/core/src/json_helpers.zig -Mcore_io=libs/core/src/io_helpers.zig -ffuzz --test-filter "fuzz governor"
```
