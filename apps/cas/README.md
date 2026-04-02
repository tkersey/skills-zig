# cas-zig-cli

Zig CLI utilities for Codex app-server validation, request fanout, and swarm conformance checks.

## Files

- `scripts/cas.zig`
- `scripts/budget_governor.zig`
- `scripts/cas_conformance_suite.zig`
- `scripts/cas_smoke_check.zig`
- `scripts/cas_instance_runner.zig`
- `scripts/cas_review_session.zig`
- `scripts/cas_proxy_client.zig`

## Behavior

- `cas` dispatches `conformance`, `smoke_check`, `instance_runner`, and `review_session`.
- `cas_conformance_suite` verifies claim-safe wave handling, stale-claim reclaim, mesh result accountability, and bounded overload retry behavior.
- `cas_smoke_check` verifies the native v2 handshake plus `experimentalFeature/list`, `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, and `turn/steer`.
- `cas_instance_runner` executes one app-server method per isolated instance and now supports native responses for:
  - `item/commandExecution/requestApproval`
  - `item/fileChange/requestApproval`
  - `item/permissions/requestApproval`
  - `item/tool/requestUserInput`
  - `mcpServer/elicitation/request`
  - `item/tool/call`
- By default, permissions requests are denied, request-user-input questions are answered with the first option label when present, MCP elicitations are declined, and dynamic tool calls return `success: false` with an explanatory text item.
- `cas_review_session` starts detached `review/start` turns, persists the detached `reviewThreadId` as the recoverable handle, appends raw request/response artifacts to an NDJSON log, supports fresh-process `status`, `wait`, and `interrupt`, treats `start -> wait` as the primary flow, and keeps `start --wait` only as a convenience wrapper over the same lifecycle.
- `cas review_session start` now supports `--parent-mode auto|fresh|reuse`. `reuse` rejects unsafe parent threads, and fresh-parent startup retries once after a bootstrap materialization turn when older Codex builds cannot detach review from a just-created parent thread.
- `cas review_session` now forwards the native approval/runtime overrides already supported by the CAS Zig client: `--exec-approval`, `--file-approval`, `--permissions-approval`, `--request-user-input-response-json`, `--elicitation-action`, `--elicitation-content-json`, `--dynamic-tool-response-json`, and `--read-only`.
- JSON review-session output now includes `resolvedCodexPath`, `resolvedCodexVersion`, `compatibilityVerdict`, `failureCode`, `failureHint`, plus optional `fallback*` fields when `--fallback native-review` is used.
- Terminal review failures are now classified more precisely: `review_interrupted`, `approval_denied`, `review_failed`, `review_output_missing`, `parent_thread_not_materialized`, and `unsafe_parent_thread_state`.
- Repo-owned first-party callers should keep native fallback caller-owned: treat `start -> wait` as one detached CAS attempt, and switch to native `codex review` outside CAS after inspecting the JSON verdict when the resolved runtime is incompatible.

## API Examples

```bash
# Run the dispatcher help surface.
cas --help

# Start a detached review session for the working tree.
cas review_session start \
  --cwd /path/to/workspace \
  --uncommitted \
  --json

# Reuse only a clean materialized parent thread.
cas review_session start \
  --cwd /path/to/workspace \
  --parent-thread-id thr_parent \
  --parent-mode reuse \
  --base main \
  --json

# Start detached review and keep the handle.
cas review_session start \
  --cwd /path/to/workspace \
  --base main \
  --json

# Poll a detached review session from a fresh process.
cas review_session wait \
  --review-thread-id thr_123 \
  --timeout-ms 300000 \
  --json

# Convenience wrapper when one process is preferred.
cas review_session start \
  --wait \
  --cwd /path/to/workspace \
  --base main \
  --fallback native-review \
  --json

# Run one conformance scenario with JSON output.
cas conformance --cwd /path/to/workspace --scenario mesh_row_accountability --json

# Filter thread/list by title substring.
cas instance_runner \
  --cwd /path/to/workspace \
  --method thread/list \
  --params-json '{"cursor":null,"limit":10,"searchTerm":"rollback"}' \
  --json

# Start a turn on an existing thread.
cas instance_runner \
  --cwd /path/to/workspace \
  --method turn/start \
  --params-json '{"threadId":"thr_123","input":[{"type":"text","text":"summarize the repo"}]}' \
  --json

# Grant requested permissions for the current request and accept an elicitation payload.
cas instance_runner \
  --cwd /path/to/workspace \
  --method turn/start \
  --params-json '{"threadId":"thr_123","input":[{"type":"text","text":"continue"}]}' \
  --permissions-approval grant-session \
  --elicitation-action accept \
  --elicitation-content-json '{"confirmed":true}' \
  --json
```

## Validation

```bash
zig build test-cas
zig build build-cas -Doptimize=ReleaseFast
zig build run-cas-conformance-suite
bash apps/cas/scripts/perf/budget_governor_gate.sh

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_json --dep core_io -Mroot=apps/cas/scripts/budget_governor.zig -Mcore_json=libs/core/src/json_helpers.zig -Mcore_io=libs/core/src/io_helpers.zig -ffuzz --test-filter "fuzz governor"
```
