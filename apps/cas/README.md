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

## Behavior

- `cas` dispatches `account`, `capabilities`, `conformance`, `goal`, `smoke_check`, `instance_runner`, `review`, and `session_inquiry`.
- `cas_account` reads account status through safe app-server account APIs. It reports account/auth/rate-limit status, optional usage summary data, and a normalized budget-governor classification. It never requests token-bearing auth data, never refreshes credentials, never mutates account state, and redacts account email unless `--show-email` is supplied.
- `cas_goal` manages Codex app-server v2 thread goals through `thread/goal/get`, `thread/goal/set`, and `thread/goal/clear`. It adds safe target selection over `thread/list`, explicit `resolve`/`--dry-run` previews, create-by-default `set`, and lifecycle `wait` through `thread/resume` plus goal polling.
- `cas_conformance_suite` verifies claim-safe wave handling, stale-claim reclaim, mesh result accountability, and bounded overload retry behavior.
- `cas_smoke_check` verifies the native v2 handshake plus `experimentalFeature/list`, `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, and `turn/steer`.
- `cas_instance_runner` executes one app-server method per isolated instance and now prefers a CAS-managed loopback websocket app-server per instance, falling back to stdio when websocket bootstrap or handshake fails. Result rows and summaries now report the selected transport.
- `cas_instance_runner` and `cas review` reject the retired `--multi-agent-mode` option. Codex 0.145 ignores the corresponding request field, so CAS no longer transmits it or grants effectiveness or metric credit. Configure canonical `[agents]` settings and current Codex reasoning effort instead. Generic `--params-json` remains caller-owned and receives no CAS mode certification.
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
- `cas review` exposes exactly three actions: `run`, `start`, and `wait`. `run` brokers one tuple-bound attempt to a terminal verdict; `start` creates one detached attempt; `wait` observes that detached attempt to a terminal result. On Codex 0.145 and newer, CAS runs the native review inline within its own fresh isolated thread because Codex's detached delivery is an ordinary prose-oriented review-agent turn and does not emit `exited_review_mode.review_output`. Parent-thread reuse is rejected on this route because Codex returns the parent ID as the inline `reviewThreadId`; requiring a fresh parent preserves one unique persisted handle per attempt. Before that inline rollout materializes, CAS preserves a structured non-terminal state and still requires the exact review turn before accepting a terminal result. A partially materialized `completed` turn that entered review mode but has not emitted its structured exit also remains non-terminal. Later `wait` calls bind completion semantics to the attempt's recorded Codex runtime; the currently installed runtime is used only for tuple-currentness checks. Older Codex runtimes retain detached delivery and their existing parent-reuse path. Process completion and prose remain non-proof on both routes.
- The review kernel is a clean schema-4 cutover. Finish active pre-kernel reviews before upgrading: current CAS intentionally rejects pre-kernel session records and does not discover or coordinate through pre-kernel tuple locks. After upgrading, start a current attempt with a fresh caller binding; CAS does not migrate or bridge the retired state.
- `cas review run` and `start` accept an optional `--workflow-binding-json JSON|@FILE` containing caller-owned `requestId` and `requestFingerprint` strings. CAS validates the opaque binding, binds it to the attempt identity, and returns it unchanged.
- `--custom-instructions` may accompany `--base`, `--commit`, or `--uncommitted`. CAS sends the exact supplied text as fresh-parent `developerInstructions` and sends the Git selector separately as `review/start.target`; the selector remains the source of base/head/fingerprint identity.
- Review waits default to `2700000` ms. Detached `start` defaults to `300000` ms unless `--wait` is supplied. An explicit positive `--timeout-ms` value always wins.
- On Codex 0.145 and newer, CAS sets `excludeTurns:true` on metadata-only `thread/resume` requests. Older runtimes retain the prior parameter shape.
- `cas_session_inquiry` is the experimental controller for `$retrace` historical decision replay. It requires Ledger-validated DCP-v2/RIP-v1 inputs, independently verifies their released identities and exact inquiry carriers, derives app-server compatibility from generated Codex schemas, enforces read-only/no-network/no-approval policy, persists SIR/FIR-oriented audit artifacts, and fails closed when source, permission, budget, or anchor gates are not satisfied. It never calls `thread/shellCommand`.
- Thread-backed DCPs use `thread_fork` lineage with app-server `thread/fork` plus rollback anchoring. Rollout-backed DCPs with `source.thread_id = null` use `rollout_transcript` lineage: CAS verifies the DCP source and retained-anchor digests from `source.rollout_path`, requires `workspace_policy = transcript_only`, starts a fresh inquiry thread, and sends one bounded transcript-context `turn/start`. Rollout transcript replay is not live workspace reconstruction.
- Thread-backed inquiry rejects paginated source history before `thread/fork`, which Codex 0.145 does not support. Use a legacy-history thread or the verified `rollout_transcript` lineage.
- SIR/FIR receipts report `lineage_mode`, `source_thread_id_present`, `source_rollout_path`, and `source_artifact_reconstructability`. Rollout transcript receipts set `workspace_reconstruction.mode = transcript_only`.
- `cas session_inquiry preflight --json` generates or reuses the Codex app-server schema cache under `~/.cache/cas/app-server-schema/<codex-version>/`, fingerprints it, and reports both `thread_fork_replay` and `rollout_transcript_replay` support.
- `cas capabilities --json` includes compiled feature flags for `session_inquiry_v1`, `dcp_v1`, `rip_v1`, `fir_v1`, exact fork/rollback anchoring, ephemeral forks, read-only inquiry, detached inquiry, `cas_rer_opaque_request_binding_v1`, `cas_review_scoped_instructions_v1`, and `cas_codex_0145_structured_review_v4` (`v1` through `v3` remain advertised for compatibility).

## API Examples

```bash
# Run the dispatcher help surface.
./zig-out/bin/cas --help

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

# Start one detached review with an opaque caller-owned request identity.
./zig-out/bin/cas review start \
  --cwd /path/to/workspace \
  --base main \
  --custom-instructions @review-prompt.txt \
  --workflow-binding-json @workflow-binding.json \
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
./zig-out/bin/cas session_inquiry preflight --json
zig build test-cas-session-inquiry
bash apps/cas/scripts/perf/budget_governor_gate.sh

# Linux-only bounded fuzz smoke (matches CI behavior).
timeout 180 zig test --dep core_json --dep core_io -Mroot=apps/cas/scripts/budget_governor.zig -Mcore_json=libs/core/src/json_helpers.zig -Mcore_io=libs/core/src/io_helpers.zig -ffuzz --test-filter "fuzz governor"
```
