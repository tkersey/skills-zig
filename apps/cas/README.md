# cas-zig-cli

Zig CLI utilities for Codex app-server validation, request fanout, and swarm conformance checks.

## Files

- `scripts/cas.zig`
- `scripts/budget_governor.zig`
- `scripts/cas_account.zig`
- `scripts/cas_conformance_suite.zig`
- `scripts/cas_goal.zig`
- `scripts/cas_goal_core.zig`
- `scripts/cas_smoke_check.zig`
- `scripts/cas_instance_runner.zig`
- `scripts/cas_review_session.zig`
- `scripts/cas_session_inquiry.zig`
- `scripts/cas_proxy_client.zig`
- `scripts/cas_app_server_contract.zig`
- `scripts/cas_app_server_preflight.zig`
- `scripts/cas_app_server_probes.zig`
- `scripts/cas_automation.zig`

## Behavior

- `cas` dispatches `account`, `app-server`, `automation`, `capabilities`, `conformance`, `goal`, `smoke_check`, `instance_runner`, `review`, and `session_inquiry`.
- `cas app-server schema` resolves the exact Codex executable, generates or reuses stable and experimental schema bundles, and checks the version-neutral app-server capability contract without running live probes. `cas app-server preflight` adds profile-scoped live probes and fails closed when a required behavior is unavailable. The full profile proves the initialize lifecycle, explicit server-request coverage, bounded overload retry, pinning, paginated and ephemeral forks, executor-root skill/resource reads, selected environment capability-root acceptance, external import history, structured review dispatch, and paginated inquiry transport. Codex version and release-channel strings are diagnostic only; compatibility comes from the selected structural and behavioral profile for the exact resolved binary.
- App-server preflight supports stdio, CAS-managed loopback WebSocket, explicit loopback WebSocket, and Unix-domain WebSocket transports. Explicit selections never fall back. `auto` may fall back from managed WebSocket to stdio only when managed startup fails before the first RPC. The report records the selected transport and endpoint identity. An outbound `--code-mode-host` remains distinct from the inbound CAS transport and is reported only as a redacted origin plus digest.
- `cas automation doctor [--json]` opens the existing Codex database read-only, checks required tables and SQLite affinities while admitting additive columns, validates row/file parity, statuses, cwd JSON, RRULEs, Codex resolution, and the scheduler surface, and reports `cas-automation-doctor/v1` with `safeToMutate`. Mutations apply the same schema gate, validate before writing, commit database changes transactionally, and report a later file-sync divergence as committed database state requiring `doctor` repair.
- `cas automation scheduler status --json` reports `cas-automation-scheduler-status/v1` with installed/loaded state, label, plist path, program arguments, `cas-automation|standalone-cron|unknown` surface, and migration status. `scheduler install --replace` adopts a same-label standalone-Cron job; CAS never creates a second migration label or overwrites unexpected arguments implicitly.
- `cas_account` reads account status through safe app-server account APIs. It reports account/auth/rate-limit status, optional usage summary data, and a normalized budget-governor classification. It never requests token-bearing auth data, never refreshes credentials, never mutates account state, and redacts account email unless `--show-email` is supplied.
- `cas_goal` manages Codex app-server v2 thread goals through `thread/goal/get`, `thread/goal/set`, and `thread/goal/clear`. It adds safe target selection over `thread/list`, explicit `resolve`/`--dry-run` previews, create-by-default `set`, and lifecycle `wait` through `thread/resume` plus goal polling.
- `cas_conformance_suite` verifies claim-safe wave handling, stale-claim reclaim, mesh result accountability, and bounded overload retry behavior.
- `cas_smoke_check` verifies the native v2 handshake plus `experimentalFeature/list`, `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, and `turn/steer`.
- `cas_instance_runner` executes one app-server method per isolated instance and prefers a CAS-managed loopback WebSocket app-server per instance. `auto` may use stdio only when managed startup fails before request-capable initialization; a handshake or later protocol failure never triggers a second transport. Result rows and summaries report the selected transport.
- `cas_instance_runner` and `cas review` reject the retired `--multi-agent-mode` option. CAS no longer transmits a request-scoped multi-agent field or grants it effectiveness or metric credit. Configure canonical `[agents]` settings and current Codex reasoning effort instead. Generic `--params-json` remains caller-owned and receives no CAS mode certification.
- `cas_smoke_check`, `cas_instance_runner`, `cas review`, and `cas_conformance_suite` accept `--hooks inherit|off|require-observed`. `inherit` is the default, `off` starts CAS-owned app-servers with `--disable codex_hooks`, and `require-observed` fails with `hook_not_observed` when no `hook/started` or `hook/completed` notifications were captured.
- JSON outputs include `hookSummary` on hook-aware lanes. Bad observed hook statuses fail closed with precedence `hook_blocked`, then `hook_failed`, then `hook_stopped`; unsupported hook-capable runtime surfaces fail with `hooks_unsupported`.
- `cas_instance_runner` supports native responses for:
  - `item/commandExecution/requestApproval`
  - `item/fileChange/requestApproval`
  - `item/permissions/requestApproval`
  - `item/tool/requestUserInput`
  - `mcpServer/elicitation/request`
  - `item/tool/call`
- By default, permissions requests are denied, request-user-input questions are answered with the first option label when present, MCP elicitations are declined, and dynamic tool calls return `success: false` with an explanatory text item.
- `cas review` exposes exactly three actions: `run`, `start`, and `wait`. `run` brokers one tuple-bound attempt to a terminal verdict; `start` creates one durable attempt; `wait` observes that same handle. `run` and `start` first require the exact Codex binary to pass live `cas app-server preflight --profile review` over the managed WebSocket transport. CAS then runs the native review inline within its own fresh isolated thread; parent-thread reuse is rejected because inline delivery returns the parent ID as `reviewThreadId`. Before that rollout materializes, CAS preserves a structured non-terminal state and still requires the exact review turn plus `exited_review_mode.review_output` before accepting a semantic result. Process completion and prose are not proof. Receipts bind the resolved binary path/version/digest, stable and experimental schema digests, contract id, transport, and redacted Code Mode host identity. Later `wait` calls keep completion semantics bound to the attempt's recorded runtime.
- The review kernel is a clean schema-4 cutover. CAS rejects an incompatible runtime before `review/start` and does not bridge retired session or tuple-lock state.
- `cas review run` and `start` accept an optional `--workflow-binding-json JSON|@FILE` containing caller-owned `requestId` and `requestFingerprint` strings. CAS validates the opaque binding, binds it to the attempt identity, and returns it unchanged. A workflow-bound `start` is admitted only with `--wait`, so one CAS process owns the notification channel from `review/start` through terminal evidence. Without `--wait`, CAS returns `workflow_bound_review_requires_owner_lived_wait` before Codex resolution, app-server launch, tuple locking, session persistence, or `review/start`; this path cannot consume attempt or recovery credit. Unbound detached starts and historical `wait` remain available for diagnostics and compatibility.
- `--custom-instructions` may accompany `--base`, `--commit`, or `--uncommitted`. CAS sends the exact supplied text as fresh-parent `developerInstructions` and sends the Git selector separately as `review/start.target`; the selector remains the source of base/head/fingerprint identity.
- Review waits default to `2700000` ms. Unbound detached `start` defaults to `300000` ms unless `--wait` is supplied. Workflow-bound starts require `--wait`. An explicit positive `--timeout-ms` value always wins.
- CAS sets `excludeTurns:true` on metadata-only `thread/resume` requests when the selected runtime profile admits that capability.
- `cas_session_inquiry` is the experimental controller for `$retrace` historical decision replay. It consumes caller-supplied Ledger validation receipts for DCP-v2/RIP-v1 inputs, binds them to the exact carrier bytes, independently verifies content identity and inquiry invariants, derives app-server compatibility from generated Codex schemas, enforces read-only/no-network/no-approval policy, persists SIR/FIR-oriented audit artifacts, and fails closed when source, permission, budget, or anchor gates are not satisfied. CAS does not execute or bundle Ledger. It never calls `thread/shellCommand`.
- Thread-backed DCPs use `thread_fork` lineage with app-server `thread/fork` plus rollback anchoring. Rollout-backed DCPs with `source.thread_id = null` use `rollout_transcript` lineage: CAS verifies the DCP source and retained-anchor digests from `source.rollout_path`, requires `workspace_policy = transcript_only`, starts a fresh inquiry thread, and sends one bounded transcript-context `turn/start`. Rollout transcript replay is not live workspace reconstruction.
- Thread-backed inquiry accepts both legacy and paginated source history. Paginated inquiry uses an exact completed fork boundary, `excludeTurns:true`, ascending `thread/turns/list`, and anchor re-digestion; it never mistakes an interrupted suffix for completed history. A failed paginated fork is a structured compatibility/transport failure and does not silently switch lineage. `rollout_transcript` remains available only when thread-fork lineage is unavailable for a separately evidenced reason.
- SIR/FIR receipts report `lineage_mode`, `source_thread_id_present`, `source_rollout_path`, and `source_artifact_reconstructability`. Rollout transcript receipts set `workspace_reconstruction.mode = transcript_only`.
- `cas session_inquiry preflight --json` consumes the live `session-inquiry` app-server profile, derives its route-specific fork shapes from the shared cache under `~/.cache/cas/app-server-schema/<resolved-path-fingerprint>/<codex-version>/`, and reports both `thread_fork_replay` and `rollout_transcript_replay` support. A thread-backed inquiry requires the exact paginated-fork witness; transcript support cannot admit that lineage.
- `cas capabilities --json` includes compiled feature flags for the current implementation, including `cas_app_server_contract_v1`, `cas_app_server_schema_probe_v1`, and `cas_structured_review_v1`. These describe CAS capabilities, not a required Codex version.

## API Examples

```bash
# Run the dispatcher help surface.
./zig-out/bin/cas --help

# Inspect the exact runtime schemas without live behavioral probes.
./zig-out/bin/cas app-server schema \
  --cwd /path/to/workspace \
  --codex-path /exact/path/to/codex \
  --profile full \
  --json

# Require the core structural and live app-server contract.
./zig-out/bin/cas app-server preflight \
  --cwd /path/to/workspace \
  --codex-path /exact/path/to/codex \
  --profile core \
  --json

# Inspect automation store and scheduler compatibility without mutation.
./zig-out/bin/cas automation --db /path/to/codex-dev.db doctor --json
./zig-out/bin/cas automation scheduler status --json

# Adopt an existing same-label standalone-Cron scheduler.
./zig-out/bin/cas automation scheduler install --replace

# Read sanitized account/auth/rate-limit status.
./zig-out/bin/cas account status \
  --cwd /path/to/workspace \
  --json

# Include usage summary data and explicitly reveal the account email.
./zig-out/bin/cas account status \
  --cwd /path/to/workspace \
  --usage \
  --show-email \
  --json

# Preview the latest materialized goal target for a repository.
./zig-out/bin/cas goal resolve \
  --cwd /path/to/workspace \
  --latest \
  --json

# Create or update a goal, creating a materialized thread when no target is supplied.
./zig-out/bin/cas goal set \
  --cwd /path/to/workspace \
  --objective "finish the review" \
  --json

# Clear a selected thread goal after previewing the selected target.
./zig-out/bin/cas goal clear \
  --cwd /path/to/workspace \
  --latest \
  --dry-run \
  --json

./zig-out/bin/cas goal clear \
  --cwd /path/to/workspace \
  --latest \
  --json

# Resume the thread and wait for a terminal goal status.
./zig-out/bin/cas goal wait \
  --cwd /path/to/workspace \
  --thread-id thr_123 \
  --timeout-ms 300000 \
  --json

# Broker one tuple-bound review verdict for the working tree.
./zig-out/bin/cas review run \
  --cwd /path/to/workspace \
  --uncommitted \
  --timeout-ms 2700000 \
  --json

# Start one owner-lived review with an opaque caller-owned request identity.
./zig-out/bin/cas review start \
  --wait \
  --cwd /path/to/workspace \
  --base main \
  --custom-instructions @review-prompt.txt \
  --workflow-binding-json @workflow-binding.json \
  --timeout-ms 2700000 \
  --json

# Wait for the detached review to reach a terminal result.
./zig-out/bin/cas review wait \
  --cwd /path/to/workspace \
  --review-thread-id thr_123 \
  --timeout-ms 2700000 \
  --json

# Check runtime compatibility before historical replay.
./zig-out/bin/cas session_inquiry preflight --json

# Run a bounded inquiry from DCP/RIP inputs.
./zig-out/bin/cas session_inquiry run \
  --capsule capsule.json \
  --capsule-definition capsule.definition.json \
  --capsule-validation capsule.validation.json \
  --plan plan.json \
  --plan-definition plan.definition.json \
  --plan-validation plan.validation.json \
  --receipt-dir .retrace/INQ-001 \
  --sandbox read-only \
  --json

# Start detached state and inspect the persisted handle.
./zig-out/bin/cas session_inquiry start \
  --capsule capsule.json \
  --capsule-definition capsule.definition.json \
  --capsule-validation capsule.validation.json \
  --plan plan.json \
  --plan-definition plan.definition.json \
  --plan-validation plan.validation.json \
  --receipt-dir .retrace/INQ-001 \
  --json
./zig-out/bin/cas session_inquiry status --inquiry-id INQ-001 --json

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
./zig-out/bin/cas_account --help
./zig-out/bin/cas_conformance_suite --help
./zig-out/bin/cas_session_inquiry --help
./zig-out/bin/cas goal --help
./zig-out/bin/cas app-server schema --cwd . --profile full --json
./zig-out/bin/cas app-server preflight --cwd . --profile core --json
./zig-out/bin/cas session_inquiry preflight --json
zig build test-cas-session-inquiry
bash apps/cas/scripts/perf/budget_governor_gate.sh

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_json --dep core_io -Mroot=apps/cas/scripts/budget_governor.zig -Mcore_json=libs/core/src/json_helpers.zig -Mcore_io=libs/core/src/io_helpers.zig -ffuzz --test-filter "fuzz governor"
```
