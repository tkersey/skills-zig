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
- `scripts/cas_trial.zig`
- `scripts/cas_proxy_client.zig`

## Behavior

- `cas` dispatches `account`, `capabilities`, `conformance`, `goal`, `smoke_check`, `instance_runner`, `review_session`, and `session_inquiry`; on macOS it also dispatches `trial`.
- `cas trial` is the macOS-only HCTP-v1 single-execution runner. It atomically claims a
  registered lane-and-lease identity before launching one registered executor, accepts
  lane leases and visible case input only through protected file descriptors,
  creates a fresh workspace, rejects duplicate claims, bounds the observable
  execution lifecycle, enforces a wall-clock deadline, preserves evidence, and
  emits an optionally
  Ed25519-signed `hylo-run-receipt/v1`. No-retry and no-fork claims require
  absolute, canonical, no-symlink executor and Ledger origins whose binary
  fingerprints are frozen in the trial trust policy. Before claim, CAS reads
  each held origin exactly once and materializes those admitted bytes as a
  mode-`0500`, content-addressed executable in a CAS-private mode-`0700` store.
  It spawns only the staged path and revalidates the held stage plus its pathname
  immediately before and after execution; later replacement of the origin does
  not change the executed bytes. Trusted local receipts retain the origin path
  and admitted fingerprint; portable proof projections omit local locators.
  Neither form serializes the private stage locator. Apple platform
  executables are rejected when the source is restricted or any embedded Mach-O
  CodeDirectory has a nonzero platform identifier, because macOS kills a
  byte-identical user-store copy of that executable class. Ordinary scripts and
  non-platform project executables remain admissible. CAS asks the independently
  authorized staged Ledger binary to authenticate
  the registered trial, durable start, lease digest, visible-input fingerprint,
  and selected opaque arm before claiming the lane. Historical lanes compile
  one Retrace replay plan and normalize one FIR-v1. For non-target factors and
  immutable null sentinels, CAS resolves only `git-blob-json:<oid>` carriers,
  verifies that each Git object is a blob, canonicalizes and fingerprints its
  JSON, archives the exact bytes read-only inside the lane, and requires the
  frozen executor to observe
  the registered ref and fingerprint before CAS signs the receipt.
  `target_snapshot` lanes reconstruct the registration-captured Git blobs into
  a runner-owned read-only target package, never deliver a mutable `INDEX`
  reference to the executor, and require exact pre/post no-follow tree equality,
  including entry set, types, modes, directory ancestry, and file bytes.
  Executor stdout and stderr are captured through separate nonblocking pipes
  into CAS-reserved, held-inode carriers bounded to 64 MiB per stream and
  persisted at mode `0600`. The exact bound succeeds; the first additional byte
  causes CAS to kill and reap the process group, retain only the bounded
  prefixes, record capture completeness and truncation, and normalize one signed
  `aborted / executor_output_limit_exceeded` terminal receipt. Carrier-path
  replacement is an invalid, incomplete capture rather than substitute evidence.
  After the direct child is reaped, a short drain grace remains bounded by the
  original monotonic lane deadline; if process termination or pipe EOF cannot be
  proved, CAS leaves the claimed lane nonterminal rather than sealing mutable
  evidence. Claims,
  terminal receipts, failure details, and cleanup receipts are create-only,
  mode-sealed, and fingerprint-bound through content-addressed terminal and
  cleanup controls; `status` and `cleanup` reverify the complete control chain.
  These checks detect persistent drift under the single-controller model.
  macOS is the sole supported HCTP runtime. The private staged-path checks do not
  prove that no same-user transient mutate-and-restore occurred between
  observations, and `os_confinement` remains `false`: CAS does not claim to
  contain hostile native code running as the same user.
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
- `cas review_session run` is the brokered one-review path. It waits by default, returns `reviewVerdict`, reports `reviewBrokerDecision`, normalizes terminal same-tuple evidence, and auto-replaces an active same-tuple attempt only when prior transport loss plus dead owner/server liveness is proven.
- Review wait defaults are action-aware: `run`, `start --wait`, `wait`, and `lane review` use `1800000` ms; lane smoke/suites and control paths use `300000` ms. An explicit positive `--timeout-ms` value always wins.
- `cas review_session run`, `start`, and `lane review` accept an optional atomic `--workflow-binding-json JSON|@FILE`. For new runs the binding contains only caller-owned `requestId` and `requestFingerprint` strings. CAS validates both as non-empty, binds the object to review-lock and CAS-RER identity, and returns it unchanged.
- `--custom-instructions` may accompany `--base`, `--commit`, or `--uncommitted`. CAS sends the exact supplied prompt as the native custom review target while retaining the selector for base/head/fingerprint identity and recovery.
- `cas review_session current` and `list` return the complete valid history for the exact native repo/base/head/target-fingerprint and Codex-thread scope when no workflow binding is supplied. Passing `--workflow-binding-json` selects one exact binding. Account identity and resolved Codex path/version do not hide historical records.
- `CAS-CURRENT-v2` and `CAS-LIST-v2` report `contextIdentityMatches` separately from immutable `CAS-RER-v1 principal.proofUsable`. The current flag compares runtime, principal, thread, tuple, and optional opaque binding without hiding historical records when those facts drift.
- `CAS-RER-v1 workflowBinding` remains optional. Import preserves pre-0.2.75 non-empty binding objects as historical compatibility evidence; new review runs require the two-field opaque shape. CAS never attaches, relabels, or interprets an imported binding.
- `cas review_session start` supports `--parent-mode auto|fresh|reuse`. `reuse` rejects unsafe parent threads. On Codex `0.118.x`, `auto` pre-materializes a fresh parent thread before detached `review/start`; `fresh` still forces the literal fresh-parent attempt and only retries after bootstrap materialization if the runtime rejects it.
- `cas review_session status --latest --json` and `cas review_session wait --latest --json` select the newest persisted review-session record, so callers can inspect tuple binding and current status without manually listing `~/.codex/cas/review_sessions/*.json`.
- `cas review_session` now forwards the native approval/runtime overrides already supported by the CAS Zig client: `--exec-approval`, `--file-approval`, `--permissions-approval`, `--request-user-input-response-json`, `--elicitation-action`, `--elicitation-content-json`, `--dynamic-tool-response-json`, and `--read-only`.
- `cas review_session start` and `cas review_session lane review` accept `--multi-agent-mode explicit-request-only|proactive` for the fresh parent `thread/start` and bootstrap `turn/start` request flow. Reused parent threads are reported as unproven because CAS cannot prove it changed inherited parent execution context.
- JSON review-session output now includes `resolvedCodexPath`, `resolvedCodexVersion`, `compatibilityVerdict`, `selectedTransport`, `selectionReason`, `degradedFallback`, `managedServerPid`, `managedServerListenUrl`, `orphanTtlSeconds`, `requestedMultiAgentMode`, `effectiveMultiAgentMode`, `multiAgentModeSupport`, `multiAgentModeMetricEligible`, `failureCode`, `failureHint`, plus optional `fallback*` fields when `--fallback native-review` is used.
- `cas review_session lane smoke` starts a current persistent lane and verifies that the target tuple can create a first detached review attempt.
- `cas review_session lane review` includes a compact `reviewVerdict` object for caller control flow. The full receipt remains the audit artifact. Pass `--verdict-only` to emit only `reviewVerdict` while preserving the same exit semantics.
- `cas review_session run`, `cas review_session start`, and `cas review_session lane review` accept `--fresh-attempt REASON` to start a new same-tuple review after a terminal or normalized receipt. This never bypasses live active review locks or account/resource exhaustion locks.
- `cas review_session receipt classify`, `cas review_session receipt gate`, and `cas review_session lock gate` provide the native Zig validator/classifier helpers for `$cas` skill fixtures and review receipts. These replace the old skill-local Python helper scripts.
- Terminal review failures are now classified more precisely: `review_interrupted`, `approval_denied`, `review_failed`, `review_output_missing`, `parent_thread_not_materialized`, and `unsafe_parent_thread_state`.
- If a websocket-backed detached review already exists and `wait` cannot reconnect to its managed transport, `--fallback native-review` now returns an explicit degraded native-review success and persists that terminal fallback in the review-session record. It is not detached-review output.
- Repo-owned first-party callers should keep native fallback caller-owned: treat `start -> wait` as one detached CAS attempt, and switch to native `codex review` outside CAS after inspecting the JSON verdict when the resolved runtime is incompatible.
- `cas_session_inquiry` is the experimental controller for `$retrace` historical decision replay. It validates DCP-v2/RIP-v1 inputs, derives app-server compatibility from generated Codex schemas, enforces read-only/no-network/no-approval policy, persists SIR/FIR-oriented audit artifacts, and fails closed when source, permission, budget, or anchor gates are not satisfied. It never calls `thread/shellCommand`.
- Thread-backed DCPs use `thread_fork` lineage with app-server `thread/fork` plus rollback anchoring. Rollout-backed DCPs with `source.thread_id = null` use `rollout_transcript` lineage: CAS verifies the DCP source and retained-anchor digests from `source.rollout_path`, requires `workspace_policy = transcript_only`, starts a fresh inquiry thread, and sends one bounded transcript-context `turn/start`. Rollout transcript replay is not live workspace reconstruction.
- SIR/FIR receipts report `lineage_mode`, `source_thread_id_present`, `source_rollout_path`, and `source_artifact_reconstructability`. Rollout transcript receipts set `workspace_reconstruction.mode = transcript_only`.
- `cas session_inquiry preflight --json` generates or reuses the Codex app-server schema cache under `~/.cache/cas/app-server-schema/<codex-version>/`, fingerprints it, and reports both `thread_fork_replay` and `rollout_transcript_replay` support.
- `cas capabilities --json` includes compiled feature flags for `session_inquiry_v1`, `dcp_v1`, `rip_v1`, `fir_v1`, exact fork/rollback anchoring, ephemeral forks, read-only inquiry, detached inquiry, `cas_rer_opaque_request_binding_v1`, `cas_review_history_v2`, and `cas_review_scoped_instructions_v1`.

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
./zig-out/bin/cas review_session run \
  --cwd /path/to/workspace \
  --uncommitted \
  --timeout-ms 1800000 \
  --json

# Bind a review atomically to an opaque caller-owned request identity.
./zig-out/bin/cas review_session run \
  --cwd /path/to/workspace \
  --base main \
  --custom-instructions @review-prompt.txt \
  --workflow-binding-json @workflow-binding.json \
  --timeout-ms 1800000 \
  --json

# Read all same-tuple/thread history, or filter to the exact binding.
./zig-out/bin/cas review_session list \
  --cwd /path/to/workspace \
  --base main \
  --custom-instructions @review-prompt.txt \
  --codex-thread-id thr_workflow \
  --json
./zig-out/bin/cas review_session list \
  --cwd /path/to/workspace \
  --base main \
  --custom-instructions @review-prompt.txt \
  --codex-thread-id thr_workflow \
  --workflow-binding-json @workflow-binding.json \
  --json

# Start a detached review session for lower-level lifecycle control.
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
  --timeout-ms 1800000 \
  --json

# Inspect the newest persisted review session and tuple binding.
./zig-out/bin/cas review_session status \
  --latest \
  --json

# Classify and validate saved CAS review artifacts with native helpers.
./zig-out/bin/cas review_session receipt classify \
  --path receipts.jsonl \
  --format jsonl
./zig-out/bin/cas review_session receipt gate \
  --path review.json \
  --format json
./zig-out/bin/cas review_session lock gate \
  --path tuple-lock.json \
  --format json

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
