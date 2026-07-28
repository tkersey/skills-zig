# Seq

Seq 1.0 compiles passive observation definitions into bounded native plans and
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
zig build -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseFast
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

Seq reads Codex rollout/session sources, supported OpenCode execution sources,
and caller-supplied immutable relations. It does not scan memory roots, Ledger
stores, artifact directories, or arbitrary durable stores implicitly.

Select OpenCode prompt history explicitly with
`--path ~/.local/state/opencode/prompt-history.jsonl`. Its prompts, parts, and
tool lifecycle appear through the same physical relations used by passive
observations; no source-specific command is restored.

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
