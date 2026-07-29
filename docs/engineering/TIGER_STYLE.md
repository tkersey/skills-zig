# TigerStyle for skills-zig

## Status

This is the engineering contract for new Zig code and for Zig code materially
changed in this repository.

It adapts, rather than copies, TigerBeetle's
[TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
The shared priority is:

1. Safety.
2. Performance.
3. Developer experience.

The rules below are specialized for bounded command-line tools, local evidence
stores, process orchestration, and deterministic audit artifacts.

## Design before implementation

A change starts with a precise model, not a patch. State these before writing
code:

- The authority boundary: what the component may observe, mutate, or publish.
- The positive space: states and inputs that are expected.
- The negative space: states and inputs that must be rejected.
- Every bound: bytes, rows, retries, processes, output, time, and diagnostics.
- The durable identity: which fields make an artifact or decision immutable.
- The recovery law: what happens after interruption, partial persistence, or
  stale ownership.

Do not defer a known correctness problem to a later cleanup. A missing feature
is acceptable. A knowingly weak invariant is not.

## Safety

### Bound everything

All input, output, iteration, retry, queue, process, and persistence paths must
have explicit limits. Limits are named constants with units or qualifiers last,
for example `output_bytes_max` and `timeout_ms_review`.

Intentional non-terminating loops require a same-line `tiger: event-loop`
comment and a documented reason that the loop is externally controlled.
Ordinary work loops must be structurally bounded.

Production algorithms must not use recursion. Replace recursive traversal with
an explicit stack or queue whose capacity is visible and checked.

Source lines are limited to 100 columns. Zig multiline-string data lines are
exempt because wrapping passive JSON or text changes data layout and inflates
fixtures without making executable code clearer.

### Distinguish programmer errors from operating errors

Programmer errors violate an invariant and should be asserted. Operating errors
are expected environmental outcomes and must be returned, classified, or
reported. Never discard an error with `catch {}` or turn an expected operating
error into `unreachable`.

Assertions should cover both sides of important boundaries. Validate an event
before persistence and validate it again after loading. Assert relationships
between compile-time constants where one limit depends on another.

### Keep capabilities explicit

Thread allocators, I/O capabilities, clocks, stores, and process policy through
function boundaries. Do not acquire a convenient global capability when the
caller already owns the correct one. Pass library options explicitly when a
default could change semantics.

The process-owned `std.process.Init.io` is the default carrier for process
creation. A global single-threaded I/O instance is not a substitute for an
owned process capability.

### Validate positive and negative space

Every parser, state transition, and validator needs tests for:

- A representative valid input.
- Each invalid field type.
- Missing required data.
- Boundary values immediately below, at, and above each limit.
- Valid data becoming invalid through one mutation.
- Stale, duplicated, reordered, or mismatched identity.
- Failure and recovery behavior.

A single happy-path fixture is not sufficient evidence.

### Minimize state and scope

Declare values close to their first use. Avoid aliases to mutable state. Keep
one owner for state transitions and make helpers compute results rather than
mutating unrelated state.

New functions and test blocks are limited to 70 physical lines. Push branching
up into the owning function and push iteration down into focused helpers. New
Zig lines are limited to 100 columns.

## Bounded allocation policy

Unlike TigerBeetle's server data plane, these CLIs may allocate after startup.
The permission is narrow:

- Every read and process capture has a byte limit.
- Every collection has a count or byte limit.
- Ownership and deinitialization are adjacent and visually grouped.
- Arenas are preferred for request-lifetime graphs.
- Long-lived stores retain only data required by their contract.

`usize` is allowed for in-memory slice indexes and standard-library allocator
interfaces. Persisted counts, protocol fields, timestamps, and externally
visible limits use explicitly sized integer types.

## Performance

Before adding a new data path, write a rough budget for network, disk, memory,
and CPU. Include both latency and bandwidth where relevant. Optimize the
slowest frequently used resource first.

Separate control-plane decisions from data-plane scanning. Batch file reads,
store appends, and query projections where batching preserves evidence order.
Do not add caching until identity, invalidation, and memory bounds are explicit.

Performance work must preserve deterministic output and the same validation
surface. A faster path without equivalent proof is a different feature.

## Developer experience

Use descriptive `snake_case` names. Avoid abbreviations unless the domain uses
them as stable public terminology. Put units and qualifiers last. Prefer long
command-line flags in documentation and automation.

Comments explain why a constraint exists and how the code preserves it. They
are complete sentences. Commit messages explain the behavioral change and its
reason; the pull request body does not replace commit history.

Prefer Zig for repository tooling. A new dependency requires a written safety,
performance, maintenance, and supply-chain justification.

## Mechanical ratchet

`tools/tiger_style/main.zig` enforces the mechanical subset of this contract:

- 100-column lines.
- No tabs or trailing whitespace.
- No unresolved `TODO`, `FIXME`, or `HACK` comments.
- No discarded errors through `catch {}` or `catch unreachable`.
- No unmarked `while (true)` loops.
- No direct recursion in fully audited files.
- No function or test block longer than 70 lines in fully audited files.

Pull request CI fully audits new Zig files and audits every added line in
modified Zig files. This is a ratchet: existing code remains changeable, but new
violations cannot be introduced. When materially refactoring an existing file,
run the full-file audit and leave the touched functions within the contract.

```bash
zig test tools/tiger_style/main.zig
zig run tools/tiger_style/main.zig -- audit-files path/to/file.zig
zig run tools/tiger_style/main.zig -- audit-diff --base <base> --head <head>
```

The auditor is intentionally bounded. It caps diff bytes, file bytes, file
count, line count, and diagnostic count. A tool failure is a failed gate, not a
silent pass.

## Review evidence

A reviewable change includes:

- The design and authority boundary.
- Explicit limits and their rationale.
- Positive-space and negative-space tests.
- Error-path and recovery proof.
- A performance sketch when a data path changes.
- The exact commands used for validation.
- Release and compatibility impact.

Review comments should identify the violated invariant or missing proof, not
only propose a local code shape.
