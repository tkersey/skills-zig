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

- `cas` dispatches `account`, `capabilities`, `conformance`, `goal`, `smoke_check`, `instance_runner`, `review_session`, and `session_inquiry`.
- `cas_account` reads account status through safe app-server account APIs. It reports account/auth/rate-limit status, optional usage summary data, and a normalized budget-governor classification. It never requests token-bearing auth data, never refreshes credentials, never mutates account state, and redacts account email unless `--show-email` is supplied.
- `cas_goal` manages Codex app-server v2 thread goals through `thread/goal/get`, `thread/goal/set`, and `thread/goal/clear`. It adds safe target selection over `thread/list`, explicit `resolve`/`--dry-run` previews, create-by-default `set`, and lifecycle `wait` through `thread/resume` plus goal polling.
- `cas_conformance_suite` verifies claim-safe wave handling, stale-claim reclaim, mesh result accountability, and bounded overload retry behavior.
- `cas_smoke_check` verifies the native v2 handshake plus `experimentalFeature/list`, `thread/start`, `thread/resume`, `turn/start`, `turn/interrupt`, and `turn/steer`.
- `cas_instance_runner` executes one app-server method per isolated instance and now prefers a CAS-managed loopback websocket app-server per instance, falling back to stdio when websocket bootstrap or handshake fails. Result rows and summaries now report the selected transport.
- `cas_instance_runner` accepts `--multi-agent-mode explicit-request-only|proactive` for `thread/start` and `turn/start` request probes. It rejects unsupported methods and duplicate `multiAgentMode` params.
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
- `cas review_session start` and `cas review_session lane review` accept `--multi-agent-mode explicit-request-only|proactive` for the fresh parent `thread/start` and bootstrap `turn/start` request flow. Reused parent threads are reported as unproven because CAS cannot prove it changed inherited parent execution context.
- JSON review-session output now includes `resolvedCodexPath`, `resolvedCodexVersion`, `compatibilityVerdict`, `selectedTransport`, `selectionReason`, `degradedFallback`, `managedServerPid`, `managedServerListenUrl`, `orphanTtlSeconds`, `requestedMultiAgentMode`, `effectiveMultiAgentMode`, `multiAgentModeSupport`, `multiAgentModeMetricEligible`, `failureCode`, `failureHint`, plus optional `fallback*` fields when `--fallback native-review` is used.
- `cas review_session lane smoke` starts a current persistent lane and proves that the target tuple can create a first detached review attempt. Proof-sensitive callers should use persistent lane as a canonical closeout backend only after a current passing smoke exists for the repo/codex/CAS/account/target tuple; otherwise use normalized `start --wait`.
- `cas review_session lane review` includes a compact `reviewVerdict` object for caller control flow. The full receipt remains the audit artifact. Pass `--verdict-only` to emit only `reviewVerdict` while preserving the same exit semantics.
- `cas review_session start` and `cas review_session lane review` accept `--fresh-attempt REASON` to start a new same-tuple review after a terminal or normalized receipt. This never bypasses active review locks or account/resource exhaustion locks.
- `cas review_session receipt proof --clean-streak N` computes a diagnostic distinct-attempt clean streak from normalized receipts. Cached repeats of the same `reviewThreadId` do not increment the streak; pre-review/no-attempt transport failures are ignored. Proof output is not closeout-eligible, including when `--allow-reduced-principal REASON` is explicit.
- `cas review_session closeout --cwd <repo> --base <branch>` is the canonical closeout proof surface. It discovers canonical same-tuple receipts, runs missing `start --wait --fallback none` attempts when needed, and requires three distinct strong-principal clean attempts.
- `cas review_session closeout --dry-run` certifies existing canonical receipts without starting missing attempts.
- `cas review_session receipt certify --cwd <repo> --base <branch>` verifies the same strongest closeout proof from canonical receipts. It does not accept caller-selected receipt paths, globs, policy selection, clean-streak weakening, or diagnostic override flags.
- Terminal review failures are now classified more precisely: `review_interrupted`, `approval_denied`, `review_failed`, `review_output_missing`, `parent_thread_not_materialized`, and `unsafe_parent_thread_state`.
- If a websocket-backed detached review already exists and `wait` cannot reconnect to its managed transport, `--fallback native-review` now returns an explicit degraded native-review success and persists that terminal fallback in the review-session record. It is not detached-review proof.
- Repo-owned first-party callers should keep native fallback caller-owned: treat `start -> wait` as one detached CAS attempt, and switch to native `codex review` outside CAS after inspecting the JSON verdict when the resolved runtime is incompatible.
- `cas_session_inquiry` is the experimental controller for `$retrace` historical decision replay. It validates DCP-v2/RIP-v1 inputs, derives app-server compatibility from generated Codex schemas, enforces read-only/no-network/no-approval policy, persists SIR/FIR-oriented audit artifacts, and fails closed when source, permission, budget, or anchor gates are not satisfied. It never calls `thread/shellCommand`.
- Thread-backed DCPs use `thread_fork` lineage with app-server `thread/fork` plus rollback anchoring. Rollout-backed DCPs with `source.thread_id = null` use `rollout_transcript` lineage: CAS verifies the DCP source and retained-anchor digests from `source.rollout_path`, requires `workspace_policy = transcript_only`, starts a fresh inquiry thread, and sends one bounded transcript-context `turn/start`. Rollout transcript replay is not live workspace reconstruction.
- SIR/FIR receipts report `lineage_mode`, `source_thread_id_present`, `source_rollout_path`, and `source_artifact_reconstructability`. Rollout transcript receipts set `workspace_reconstruction.mode = transcript_only`.
- `cas session_inquiry preflight --json` generates or reuses the Codex app-server schema cache under `~/.cache/cas/app-server-schema/<codex-version>/`, fingerprints it, and reports both `thread_fork_replay` and `rollout_transcript_replay` support.
- `cas capabilities --json` includes compiled feature flags for `session_inquiry_v1`, `dcp_v1`, `rip_v1`, `fir_v1`, exact fork/rollback anchoring, ephemeral forks, read-only inquiry, and detached inquiry.

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
./zig-out/bin/cas review_session lane smoke \
  --cwd /path/to/workspace \
  --base main \
  --json \
  --timeout-ms 300000
./zig-out/bin/cas review_session lane review \
  --lane-id lane_123 \
  --base main \
  --timeout-ms 1800000 \
  --fallback none \
  --verdict-only

# Force a second independent same-tuple review after terminal evidence exists.
./zig-out/bin/cas review_session lane review \
  --lane-id lane_123 \
  --base main \
  --fresh-attempt "clean-run 2" \
  --timeout-ms 1800000 \
  --fallback none \
  --json

# Certify closeout from canonical distinct tuple-bound strong-principal review attempts.
./zig-out/bin/cas review_session closeout \
  --cwd /path/to/workspace \
  --base main \
  --json

# Inspect the same closeout certificate without starting missing review attempts.
./zig-out/bin/cas review_session closeout \
  --cwd /path/to/workspace \
  --base main \
  --json \
  --dry-run

# Verify the same strongest closeout certificate without caller-selected receipts.
./zig-out/bin/cas review_session receipt certify \
  --cwd /path/to/workspace \
  --base main \
  --json

# Auditable diagnostic escape hatch for old/reduced-principal receipts. This is not closeout.
./zig-out/bin/cas review_session receipt proof \
  --glob "$HOME/.codex/cas/review_sessions/*.json" \
  --cwd /path/to/workspace \
  --base main \
  --clean-streak 3 \
  --allow-reduced-principal "operator accepted reduced account isolation"

# Exploratory proactive review discovery on a fresh parent.
./zig-out/bin/cas review_session lane review \
  --lane-id lane_123 \
  --base main \
  --multi-agent-mode proactive \
  --timeout-ms 1800000 \
  --fallback none \
  --json

# Check runtime compatibility before historical replay.
./zig-out/bin/cas session_inquiry preflight --json

# Run a bounded inquiry from DCP/RIP inputs.
./zig-out/bin/cas session_inquiry run \
  --capsule capsule.json \
  --plan plan.json \
  --receipt-dir .retrace/INQ-001 \
  --sandbox read-only \
  --json

# Start detached state and inspect the persisted handle.
./zig-out/bin/cas session_inquiry start \
  --capsule capsule.json \
  --plan plan.json \
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
  --multi-agent-mode proactive \
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
