# Seq

Seq compiles passive observation definitions into bounded native plans and
reconstructs facts from agent execution and session evidence.

```text
facts + provenance + corpus scope + limitations + uncertainty
```

Seq does not validate durable artifacts or grant action, repair, review,
publication, or closure authority.

## Install

```bash
brew tap tkersey/tap
brew install seq
```

## Build and test

```bash
zig build -Doptimize=fast
zig build test -Doptimize=fast
```

The binary is written to `zig-out/bin/seq`.

## Observe

Definitions use `seq-observation-definition/v1` and require
`seq-observation-abi/v1`.

```bash
seq definition check \
  --definition <observation.json> \
  --format json

seq observe \
  --definition <observation.json> \
  --root "${CODEX_HOME:-$HOME/.codex}/sessions" \
  --since 2026-07-01T00:00:00Z \
  --param needle=review \
  --projection rows \
  --format json
```

Use `--path` or `--session-id` for an exact source. Definitions may also
declare immutable external inputs:

```bash
seq observe \
  --definition <observation.json> \
  --input facts=<facts.json> \
  --projection summary \
  --format json
```

JSON observations use `seq-observation-result/v1` and bind the definition
closure digest, selected corpus, parameters, projection, data, statistics, and
limitations. `authority_granted` is always `false`.

## Native surface

```text
seq definition check
seq definition describe
seq observe
seq explain
seq sessions
seq turns
seq session-detail
seq tool-lifecycle
seq session-graph
seq tail
seq find-session
seq datasets
seq dataset-schema
seq query
seq index
seq capabilities
seq version
```

Native commands expose only physical session structure or general optimized
execution paths. Higher-level questions belong in passive definitions beside
their semantic owner.

## Source boundary

Seq reads Codex rollout/session sources, upstream Pi session JSONL, supported
OpenCode execution sources, and caller-supplied immutable relations. It does
not scan memory roots, Ledger stores, artifact directories, or arbitrary durable
stores implicitly.

Select OpenCode prompt history explicitly with
`--path ~/.local/state/opencode/prompt-history.jsonl`. Its prompts, parts, and
tool lifecycle appear through the same physical relations used by passive
observations; no source-specific command is restored.

### Pi sessions

Require `pi-session-jsonl/v1` in `seq capabilities --format json` before reading
Pi evidence; upgrade Seq if that adapter is absent.

Select Pi files explicitly with `--path <pi-session.jsonl>`, or select their
directory with `--root`. Seq's default source remains Codex. Pi's session root
is `PI_CODING_AGENT_SESSION_DIR` when set, otherwise
`${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions`:

```bash
pi_session_root="${PI_CODING_AGENT_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions}"
seq sessions --root "$pi_session_root" --format json
```

When the host supplies `PI_SESSION_FILE`, select the current session with
`--path "$PI_SESSION_FILE"`. `seq tail --current --once` accepts `PI_SESSION_FILE`,
or resolves `PI_SESSION_ID` under the Pi session root above. If both Codex and
Pi current-session hints are present, it reports ambiguity; choose `--path`
explicitly. Existing physical commands and passive definitions use the same
Pi adapter; no separate Pi command is required. This support is for upstream
Pi, not an implicit compatibility claim for Oh My Pi.

The adapter follows [Pi's session format](https://pi.dev/docs/latest/session-format)
and reads all persisted branches in append order. Raw entry `id` and
`parentId` preserve branch provenance, and user turns follow branch ancestry
rather than the preceding user message in file order. Message text excludes
thinking blocks. Ordinary source payloads also omit thinking; explicit `raw_json`
retains the original entry. `toolCall` and `toolResult` records populate the canonical
tool lifecycle. Branch navigation is not a worker graph, and a `parentSession`
file path is not a worker session ID.

Each user entry remains one turn. Its final-answer field holds the latest
persisted answer to that entry; message/source rows retain the alternatives.
Compaction and context edits remain physical evidence rather than being
replayed to reconstruct Pi's effective model context.

Pi usage comes from each assistant message. Normalized `input_tokens` is
`input + cacheRead + cacheWrite`, `cached_input_tokens` is `cacheRead`,
`output_tokens` is `output`, and the reported total comes from `totalTokens`.
Reported `reasoning` is already included in `output`. Session/turn totals sum
only assistant requests with usage and may be partial when other requests omit
it; turn counts do not prove request-level usage completeness. Totals remain
null when no usage was observed. Standalone compaction/summary usage remains raw
and is excluded from them.
The lineage-aware `token-usage.json` definition requires Codex cumulative
counters. Requests for Pi cumulative token events fail with
`PiCumulativeTokenEventsUnavailable`; the definition does not establish Pi
corpus totals, deduplicate copied fork history, or measure Pi billing. Do not
present physical Pi session/turn sums as those quantities.

### Explicit durable inputs

Compose durable structural facts explicitly:

```bash
ledger project \
  --definition <artifact-definition.json> \
  --projection facts \
  --repo <repo> \
  --payload-only \
  --format json >facts.json

seq observe \
  --definition <observation.json> \
  --input facts=facts.json \
  --projection summary \
  --format json
```

`seq capabilities --format json` reports only observation ABIs, physical
source adapters, native operators, renderers, cache format, and generic limits.
