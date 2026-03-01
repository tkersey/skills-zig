# cron-zig-cli

Native Zig CLI for Codex automation schedule management.

## Scope
- Manage automations in SQLite (`create`, `list`, `show`, `update`, `enable`, `disable`, `run-now`, `delete`)
- Execute due automations headlessly (`run-due`)
- Manage launchd scheduling on macOS (`scheduler install|uninstall|status`)

## Runtime contract
- No Python or shell delegation in normal runtime paths.
- Automation `status` is fail-closed (`ACTIVE` or `PAUSED`).
- RRULE input is validated and canonicalized to `RRULE:`-prefixed form on write; legacy non-prefixed stored values are accepted on read.
- `run-due` is single-sweep by design (no dead `--once` flag).
- `run-due --dry-run` is read-only (no DB row mutations, no schedule advancement, no automation file writes).
- Launchd scheduler labels and `run-due --lock-label` are strict: `[A-Za-z0-9._-]`.

## Build
```bash
zig build build-cron -Doptimize=ReleaseFast
zig build test-cron
```
