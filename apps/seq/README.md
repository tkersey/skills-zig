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
  --since 2026-07-01T00:00:00Z \
  --param needle=review \
  --projection rows \
  --format json
```

Native `--path` and `--session-id` select physical sources. An observation
definition owns its semantic scope: a lineage definition can read ancestors
and include descendants of that selection. `--repo` then filters each session in
that scope, so a scoped streaming `--path` keeps descendants inside the repository
even when the selected file's own session lies outside it. Definitions may also declare
immutable external inputs:

```bash
seq observe \
  --definition <observation.json> \
  --input facts=<facts.json> \
  --projection summary \
  --format json
```

JSON observations use `seq-observation-result/v2`. Check `result_schemas` in
`seq capabilities` for this contract; the observation definition ABI remains
`seq-observation-abi/v1`. Results bind the definition closure digest, selected
corpus, declared parameters, projection, data, statistics, and limitations.
`authority_granted` is always `false`.

The envelope also includes `seq_version` and a `selection` receipt with absolute
`path`, `root`, `archive_root`, and `repo`, the selected `session_id`, and resolved UTC epoch
`since_ms`/`until_ms` bounds. This includes the absolute window resolved from
`--last`. `root` records the discovery root, including an environment/default
root; `archive_root` records the additional default Codex archive discovery
root and is null for an explicit root. `root_explicit` distinguishes default
discovery from an explicit root selector. An
external-only observation has no physical selection. Selection paths and the
session ID must be valid UTF-8; otherwise the observation fails with
`ObservationSelectionNotUtf8` before any corpus is read. `selection_digest` hashes
these resolved values with a versioned, length-framed encoding. Equivalent
`.`/`..` paths and time-zone spellings have the same selection identity; a
different window does not reuse the identity merely because it visited the same
files. Definition-owned exclusions remain declared parameters and are bound by
`parameters_digest`.

`context.as_of_ms` is the single observation instant used by every trace parser
to assess freshness. `ongoing_threshold_secs` records the policy, and
`source_metadata_digest` binds, once per session and in source-path order, the path
and exact nanosecond mtime of each trace session whose state the observation
evaluated: every admitted session with the mtime it was parsed at and, for
streaming lineage, every other discovered session that passes `--repo` with the
mtime it was discovered at, because its session relation includes them. Files skipped by selection cannot affect the
result and are not bound. Keep this context alongside corpus
identity: identical session content can have different current liveness. The
metadata digest distinguishes those inputs; it does not store a replayable
filesystem snapshot or prove that a multi-file read was atomic. Trace corpus
digests bind paths and framed source lines; external input digests bind their
supplied bytes. A `source_event_id` is a path/line/ordinal locator and must travel
with its corpus identity.

`corpus.parser_warning_count` reports parser warnings. The independent
`corpus.semantic_contamination` field is `"not_assessed"`: syntactically clean
audit prompts, quoted reports, and injected instructions can still contaminate a
semantic analysis. The owning definition or analyst must assess that question.
The former `contaminated` boolean is absent from v2.

`bounds.max_input_bytes` applies to aggregate decoded JSONL admitted for parsing.
Every strategy decides selection from a session's discovery prefix, its first line,
before charging the file against that bound, so a file whose prefix places it outside
the selectors cannot exhaust it. Discovery identity comes from the same line, and later
lines in the same read never decide selection. Every parser takes a session's identity
and lineage fields from that line too: a `session_meta` or Pi session header on a later
line establishes none (a Codex `session_meta` there adds a warning), so that file is a
session without an identity on every strategy. A prefix that omits a selected field,
such as a legacy first line without `cwd` or a timestamp, cannot exclude its file,
which is then read and charged. Linear and single-source strategies then drop that
session when its parsed `cwd` or time fails the selectors; lineage and multi-scan
graph scopes keep it.
Plain-only streaming lineage execution reserves discovered file sizes before
prefetch; compressed disk sizes are never substituted for decoded reservations.
The unreserved remainder of the bound is spare: a session that grows after
discovery may read into it, and results are admitted in order only while the
admitted decoded bytes plus the still-unconsumed reservations fit the bound. A
corpus with compressed files is parsed sequentially, and each file may read the
decoded budget that is neither admitted nor reserved by a later file. Growth
beyond the spare fails with `ObservationInputByteBoundExceeded`; a failed read
never yields a partial success. Each discovery read (a session identity or
selection prefix) reads a file's first line under the parser's line limit: at most
256 MiB of decoded bytes per file, not counting its newline. Discovery has no separate fixed
total: it is bounded by that per-file limit and the native
candidate limit of 1,000,000 session files. `stats.files_opened` counts source
file opens, including discovery reopens; `discovery_files_opened` and
`discovery_bytes_read` identify that additional work. `corpus_bytes_read` and
`discovery_bytes_read` count decoded source bytes, and `bytes_read` is their sum.
These are not compressed disk-I/O measurements.
`physical_passes` counts relation execution passes, so one pass does not imply
that lineage discovery performed no additional I/O. `bounds.max_output_bytes`
covers the entire rendered result, including the v2 envelope and its absolute
selection paths; definitions with tight output bounds may need more headroom than
under v1.

Shared graph inputs remain intact until all their consuming stages have run.
Filtering, folding, and membership joins may reuse storage only for an exclusively
owned final consumer. Numeric equality and ordering are exact for integers and
for integers compared with floats, including values above `2^53`, so `distinct`,
sorting, and joins do not depend on row order. Signed zeros compare and hash
equal. Every strategy shares one value order. Ordering predicates and comparisons
hold only between non-null values of one kind (numbers, text, or booleans), so
null, NaN, and mixed kinds never satisfy them, and NaN never equals a value.
Sorting places nulls first or last as declared in either direction. Ascending order
puts NaN after every number and kinds as text, numbers, then booleans; descending
order reverses both.
Sessions without an
identity, such as an empty rollout, do not participate in lineage joins and cannot be
linked by reachability. A lineage join or reachability checks its whole graph input
before walking it: a parent cycle fails with `ObservationGraphCycle` and a node deeper
than `bounds.max_graph_depth` parent links fails with `ObservationGraphDepthExceeded`,
on every strategy; a node exactly at the bound is admitted.

Every join a projection reaches is checked against its inputs before a strategy is
chosen, and every strategy runs that one checked form. A key, flag, output, or lineage
field that names no field of its input, an unknown key in a join's `on`, key, lineage,
or output-field object, an output `source` other than 0 or 1, a semi or anti join that
projects its right input, a flag on a non-boolean field, an unknown `kind` or key `op`,
a non-boolean `nulls_equal`, `nulls_equal: true` on an ordering key, a join without an
equality key, and a lineage join without exactly three inputs fail before any corpus is
read. Ordering keys never match a null.

A lineage definition streams (`partition-lineage-stream`) only when all of these hold:

- its projection reaches exactly one lineage join, an anti join whose left and right
  inputs are the same stage, whose projection takes only fields of that input, whose
  keys are all equality keys that pair a field of that input with itself, and whose
  lineage relates rows and nodes by `session_id` and walks `parent_session_id`;
- its local stages stay within one session: an `ordered_fold` is keyed by
  `session_id` and its `order_by` starts with `session_id`, `distinct` and joins
  are keyed by `session_id`, and a stage that outputs `session_id` copies it from
  `session_id`, a join from its left input;
- its lineage graph input reaches the sessions scan through filters, projections,
  aliases, sorts, and input-preserving derives that do not define `session_id` or
  `parent_session_id`, without limiting, ranking, or deduplicating sessions, and
  without filtering or deriving on the token count, which exists only after
  parsing;
- its projection reads no other scan, and the sessions scan declares only fields
  discovery seeds (identity, lineage, path, and token count fields).

An expression reads or copies a field only through a `field` reference, as both
expression evaluators resolve it; a string that names a field is a literal. The token
count is the sessions scan's field, not a column that a derive defines under the same
name.

Streaming reduces each session after every session its rows can inherit from: its
ancestors in the lineage join's checked graph input, and the session that its topmost
ancestor there names as parent, which a filter on the graph input may leave out. It
fails with `ObservationStreamingPartitionOutOfOrder` rather than reduce a session
before one of those. It hands the stages after the lineage join its rows and sessions in
source-path order, as the materialized graph reads them, so row order,
order-dependent stages, and the corpus digest agree across strategies. When the rows
reaching the lineage join come from a local `ordered_fold` through stages that keep
their order, they follow that fold's first sort key instead, session by session, as
the materialized fold sorts them. Rows of session files
without an identity form their own partitions, so a session-keyed local `distinct`
or join keeps them apart where the materialized graph groups their null `session_id`
values, and such a fold sorts each file's rows alone and keeps those files in
source-path order where the materialized fold sorts all of their rows together.

Any other lineage definition runs on the materialized-graph strategy over the whole
root; with `--path` or `--session-id` it fails with
`ObservationStreamingLineageShapeUnsupported`, because only the streaming strategy
reads the selection's lineage closure. That closure follows control and history
parents through every discovered session and never fails on its own: cycles and
depth fail only through the lineage graph check, as unscoped runs do. A scoped
streaming run computes the whole observation over that closure: stages after the
lineage join see only the closure's rows, so a top-k, aggregate, or join that
relates rows of different sessions answers for the closure, not for the whole root.
A streaming lineage `--session-id` that matches no discovered session passing
`--repo` fails with `SessionNotFound`, as other strategies do. Streaming lineage
indexes every discovered session, so a session id that appears twice under the root
fails it with `DuplicateObservationLineageNode`.
A `limit` or `top-k` count
bound from a parameter must lie between 1 and `bounds.max_rows`, as a literal count
must; other values fail with `InvalidObservationLimit` on every strategy. Every
strategy checks that the parameters its filters and limits use are bound before it
reads the corpus; an unbound optional parameter fails with
`MissingObservationParameter`. Graph projections that pass through
`limit` or `top_k` report the definition-bounded limitation, as linear projections
do.

Single-source graph definitions apply `--path`, `--session-id`, `--since`, and
`--until` to their corpus on every strategy, as linear definitions do; multi-scan,
lineage, and reachability graphs read the whole root and expose those selectors to
expressions.
Single-source graphs with a native `top-k` prefix stream physical selection,
filters, and row-local derivations through the native runner. Only the retained
top-k rows enter the remaining graph. `seq explain` reports this as
`bounded-native-prefix`. Adding excerpt derivations to a search therefore keeps
its path/session/time selection and avoids retaining the entire matching corpus.
A `sessions` scan never lowers to this prefix: the native runner summarizes
sessions, while graph definitions read them with the full parser, so a graph over
`sessions` runs on the materialized graph whether it ranks with `top-k` or `sort`.
The native row, retained-byte, input-byte, output, and fold-state limits still apply
(each `limit` in the prefix counts against `bounds.max_fold_states`), and each
row's derived strings share a buffer of `bounds.max_output_bytes`; a row that exceeds
it fails with `ObservationExpressionByteBoundExceeded`. The materialized graph applies
no per-row derivation bound. OpenCode prompt history and the structured relations
reach graph definitions only through this prefix; other graph strategies fail with
`GraphObservationOpenCodeUnsupported` or `StructuredRelationRequiresIndex`.

## Codex source coverage and forks

Default discovery reads both `${CODEX_HOME:-$HOME/.codex}/sessions` and
`archived_sessions`. Explicit roots stay confined to the requested directory.
Both `.jsonl` and `.jsonl.zst` rollouts are discovered; capabilities advertise
`source_encodings`. Time selectors prune canonical partitions and archived rollouts
alike, with a two-day margin: a rollout whose filename start date follows `--until`
is skipped, and one that starts before `--since` is skipped only when its
modification time also precedes the window. Use time selectors over the complete
intended corpus;
calendar directories reflect session starts and can omit resumed sessions or
needed ancestors. An empty result describes the admitted corpus, not all work
that may have occurred outside it.

Zstd decoding stays in process and verifies frame checksums. Concatenated and
skippable frames are supported. The decoder accepts an 8 MiB maximum window;
larger windows and external dictionaries fail explicitly. Each compressed
source also has an encoded-byte cap of twice its decoded allowance plus 1 MiB,
with saturating arithmetic and one sentinel byte for overrun detection. This
bounds streams that produce little or no decoded output. Native file parsing
has a 64 GiB decoded limit; observation definitions supply their own limits.
Corrupt, truncated, or unsupported compressed input cannot produce successful
empty sessions. Recognized Claude Code transcripts fail with
`UnsupportedSessionFormat`; sharing a skill installation does not add a reader.

`sessions.parent_session_id` follows history ownership: `forked_from_id`, with
legacy fallback to the control parent. `control_parent_session_id` records the
worker-control relationship independently. Different values are legitimate.
`subagent_history_start_ordinal` separates an inherited prefix from the worker's
own records when the source supplies record ordinals. Matching ancestor metadata
inside that prefix preserves primary session identity without a conflict warning;
unrelated or out-of-boundary metadata still warns.

`token_events.persisted_ordinal` preserves the source's nullable rollout ordinal;
`source_ordinal` remains the parsed occurrence index. Token rows also expose the
authoritative session's history parent and history-start boundary so passive
definitions can distinguish record provenance from ownership of a token
increment. A child record can repeat inherited counters after its history
boundary; the boundary alone does not prove new consumption.
`sessions.token_usage_observation_count` counts records asserting a total or
last-usage tuple before replay removal. Observed zero and replayed assertions
remain evidence; neutral records do not establish a usage baseline. Unsupported
adapters expose this field as null, and so does a session that a streaming lineage
run scoped by `--path` or `--session-id` leaves unparsed outside the selection's
lineage closure.

Worker edges preserve recorded control parents, successful spawn results, and
started-worker events. Declarations and failed spawns do not establish workers.
Copied prefix events do not spawn new children. When a result provides only a
task path, `agent_path` is present and `worker_session_id` remains null; no UUID
is invented. `spawned_worker_count` counts distinct observed successful links,
not attempted calls or a claim that every worker's transcript was available.
On a declared fork, records that establish a worker without a usable replay boundary or
record ordinal remain unattributed and emit a warning; declarations and failed spawns
establish no worker and emit none. Primary metadata control
links remain available independently of those creation records.
`session_edges` keeps one row per evidence source: a link recorded by both the
parent's spawn evidence and the child's control metadata yields two rows, the
parent's with `parent_path` and the child's with `worker_path`. A definition that
needs one row per link, such as a reachability over `session_edges`, should first
apply a `distinct` keyed by `parent_session_id` and `worker_session_id`.
Native `sessions` rows and linear definitions parse with the same rules as graph
strategies for session identity, lineage, model, service tier, working directory,
worker links, and token-usage observation counts, so those fields agree across
strategies. Their fast path skips a line only when its root and payload types
show that none of those fields depends on it.

Strict native row commands stage their bounded output before writing it.
Parser warnings remain failures, with source path, count, and a representative
warning in `seq-command-error/v1`; an error never follows partially emitted
rows. `session-detail` exposes the trace and its warnings for investigation.
Observations retain parser-warning counts separately from semantic contamination.

The generic `text-prefix` expression returns a bounded UTF-8 prefix:
`{"op":"text-prefix","args":[text, byte_limit]}`. It requires a nonnegative
integer byte limit, preserves null text, and stops before splitting a codepoint.
Compare the prefix with its input to detect truncation. Capabilities advertise
this through `derive` version 3 and `ordered-fold` version 2. Bounded excerpts
are not automatic redaction or semantic contamination classification.

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

### Nested tool outputs

Codex `tool_results` and `tool_lifecycle` expose an optional
`output_parts_json` field. Text-block arrays are retained in source order;
`output_text` joins their text with newlines. Each part includes its source-event
identity, source line, timestamp, and `payload_pointer` into
`source_events.payload_json`. Repeated outputs for one call retain their earlier
parts, including observations made before an asynchronous completion. Non-text
blocks and unsupported forms remain available in the original source event.

For `functions.exec` and `functions.wait` (also recorded as `exec` and `wait`),
one complete text part may contain a process-result JSON object or an array of
such objects. Seq recognizes envelopes with string `output`, nonnegative numeric
`wall_time_seconds`, and at least one of `chunk_id`, `exit_code`, or `session_id`.
Each recognized envelope appears separately in the part's `process_results`.
Its `json_pointer` addresses the JSON decoded from that part's text. These
pointers have separate roots: `payload_pointer` locates the source string;
`json_pointer` locates a reported result within that string.

An integer exit code establishes `completed` or `failed`; a reported process
session with an absent or null exit establishes `running`. Missing and invalid
exit values otherwise remain `unknown`. Seq does not assign an inner result to
the wrapper's scalar exit code, create synthetic tool calls, or infer command
text from JavaScript. Tool lifecycle completion and process success are separate
observations. Neither establishes an application's operation or capture success.

Seq recognizes complete envelopes at those boundaries, without searching prose,
code fences, nested arbitrary objects, or a process's stdout for more execution
results. Reading an earlier command's redirected output therefore preserves that
text under the read command's result. It does not create another execution of the
earlier command. Printed envelopes are reported evidence, not independent proof
that a command was invoked. Unsupported wrappers remain text with no inferred
process status. Pi and OpenCode currently return null for this additive field.

```bash
seq query --path <rollout.jsonl> \
  --spec '{"dataset":"tool_results","select":["call_id","exit_code","source_event_id","output_parts_json"],"format":"json"}'
```

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
