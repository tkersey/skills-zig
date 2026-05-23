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
- `cas_instance_runner` executes one app-server method per isolated instance and now prefers a CAS-managed loopback websocket app-server per instance, falling back to stdio when websocket bootstrap or handshake fails. Result rows and summaries now report the selected transport.
- `cas_smoke_check`, `cas_instance_runner`, `cas_review_session`, and `cas_conformance_suite` accept `--hooks inherit|off|require-observed`. `inherit` is the default, `off` starts CAS-owned app-servers with `--disable codex_hooks`, and `require-observed` fails with `hook_not_observed` when no `hook/started` or `hook/completed` notifications were captured.
- JSON outputs include `hookSummary` on hook-aware lanes. Bad observed hook statuses fail closed with precedence `hook_blocked`, then `hook_failed`, then `hook_stopped`; unsupported hook-capable runtime surfaces fail with `hooks_unsupported`.
- `cas_instance_runner` supports native responses for:
  - `item/commandExecution/requestApproval`
  - `item/fileChange/requestApproval`
  - `item/permissions/requestApproval`
  - `item/tool/requestUserInput`
  - `mcpServer/elicitation/request`
  - `item/tool/call`
- By default, permissions requests are denied, request-user-input questions are answered with the first option label when present, MCP elicitations are declined, and dynamic tool calls return `success: false` with an explanatory text item.
- `cas_review_session` now starts detached `review/start` turns over a CAS-managed loopback websocket app-server, persists the detached `reviewThreadId` as the recoverable handle, appends raw request/response artifacts to an NDJSON log, and stores websocket session metadata beside the review-session record so fresh-process `status`, `wait`, and `interrupt` can reconnect to the same detached review transport.
- `cas review_session start` supports `--parent-mode auto|fresh|reuse`. `reuse` rejects unsafe parent threads. On Codex `0.118.x`, `auto` pre-materializes a fresh parent thread before detached `review/start`; `fresh` still forces the literal fresh-parent attempt and only retries after bootstrap materialization if the runtime rejects it.
- `cas review_session` now forwards the native approval/runtime overrides already supported by the CAS Zig client: `--exec-approval`, `--file-approval`, `--permissions-approval`, `--request-user-input-response-json`, `--elicitation-action`, `--elicitation-content-json`, `--dynamic-tool-response-json`, and `--read-only`.
- JSON review-session output now includes `resolvedCodexPath`, `resolvedCodexVersion`, `compatibilityVerdict`, `selectedTransport`, `selectionReason`, `degradedFallback`, `managedServerPid`, `managedServerListenUrl`, `orphanTtlSeconds`, `failureCode`, `failureHint`, plus optional `fallback*` fields when `--fallback native-review` is used.
- `cas review_session lane review` includes a compact `reviewVerdict` object for caller control flow. The full receipt remains the audit artifact. Pass `--verdict-only` to emit only `reviewVerdict` while preserving the same exit semantics.
- Terminal review failures are now classified more precisely: `review_interrupted`, `approval_denied`, `review_failed`, `review_output_missing`, `parent_thread_not_materialized`, and `unsafe_parent_thread_state`.
- If a websocket-backed detached review already exists and `wait` cannot reconnect to its managed transport, `--fallback native-review` now returns an explicit degraded native-review success and persists that terminal fallback in the review-session record. It is not detached-review proof.
- Repo-owned first-party callers should keep native fallback caller-owned: treat `start -> wait` as one detached CAS attempt, and switch to native `codex review` outside CAS after inspecting the JSON verdict when the resolved runtime is incompatible.

## API Examples

```bash
# Run the dispatcher help surface.
./zig-out/bin/cas --help

# Start a detached review session for the working tree.
./zig-out/bin/cas review_session start \
  --cwd /path/to/workspace \
  --uncommitted \
  --json

# Reuse only a clean materialized parent thread.
./zig-out/bin/cas review_session start \
  --cwd /path/to/workspace \
  --parent-thread-id thr_parent \
  --parent-mode reuse \
  --base main \
  --json

# Split detached review with a persisted websocket-backed session handle.
./zig-out/bin/cas review_session start \
  --cwd /path/to/workspace \
  --base main \
  --json

# Fresh process reattaches to the same managed websocket transport.
./zig-out/bin/cas review_session wait \
  --review-thread-id thr_123 \
  --json

# Detached review with explicit degraded native-review fallback if websocket reconnect is lost.
./zig-out/bin/cas review_session start \
  --cwd /path/to/workspace \
  --base main \
  --fallback native-review \
  --json

# Reuse a persistent review lane and consume only the compact verdict.
./zig-out/bin/cas review_session lane start \
  --cwd /path/to/workspace \
  --hooks off \
  --json
./zig-out/bin/cas review_session lane review \
  --lane-id lane_123 \
  --base main \
  --timeout-ms 1800000 \
  --fallback none \
  --verdict-only

# Run one conformance scenario with JSON output.
./zig-out/bin/cas conformance --cwd /path/to/workspace --scenario mesh_row_accountability --json

# Require proof that Codex hook notifications were observed during a smoke lane.
./zig-out/bin/cas smoke_check \
  --cwd /path/to/workspace \
  --hooks require-observed \
  --json

# Filter thread/list by title substring.
./zig-out/bin/cas instance_runner \
  --cwd /path/to/workspace \
  --method thread/list \
  --params-json '{"cursor":null,"limit":10,"searchTerm":"rollback"}' \
  --json

# Start a turn on an existing thread.
./zig-out/bin/cas instance_runner \
  --cwd /path/to/workspace \
  --method turn/start \
  --params-json '{"threadId":"thr_123","input":[{"type":"text","text":"summarize the repo"}]}' \
  --json

# Grant requested permissions for the current request and accept an elicitation payload.
./zig-out/bin/cas instance_runner \
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
./zig-out/bin/cas_conformance_suite --help
bash apps/cas/scripts/perf/budget_governor_gate.sh

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_json --dep core_io -Mroot=apps/cas/scripts/budget_governor.zig -Mcore_json=libs/core/src/json_helpers.zig -Mcore_io=libs/core/src/io_helpers.zig -ffuzz --test-filter "fuzz governor"
```
