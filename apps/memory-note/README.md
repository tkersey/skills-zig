# memory-note

Safe append-only writer for controlled Codex custom memory-source notes.

Initial supported extensions:

- `harness`
- `learnings`
- `negative-ledger`
- `synesthesia`

Core commands:

```sh
memory-note append --extension harness --kind harness-rule --json input.json
memory-note list --extension harness
memory-note show --extension harness --id MSN-...
memory-note doctor
memory-note path --extension harness
memory-note version
```

The CLI writes immutable JSON note envelopes under:

```text
${CODEX_HOME:-$HOME/.codex}/memories/extensions/<extension>/notes/
```

It never writes compiled memory artifacts such as `memory_summary.md`, `MEMORY.md`, or memory-root `skills/*`.

## Append input

`append` reads one JSON object from `--json FILE|-`. The caller supplies source evidence:

```json
{
  "operation": "assert",
  "authority": "explicit-user-correction",
  "summary": "Proceed with grounded work when ambiguity is non-blocking.",
  "scope": {
    "kind": "global",
    "repo": null,
    "paths": []
  },
  "source_refs": [
    {
      "kind": "user-correction",
      "ref": "rollout:019-example",
      "summary": "User corrected a low-value clarification stall"
    }
  ],
  "related_ids": [],
  "supersedes_id": null,
  "payload": {
    "harness_rule": "When requirements have small non-blocking gaps, state assumptions and produce the useful grounded portion.",
    "trigger": "Minor ambiguity that does not block useful progress",
    "preferred_behavior": "Proceed with explicit assumptions",
    "failure_avoided": "Unnecessary clarification and stalled delivery",
    "verification_cue": "The response contains useful work and names material assumptions",
    "evidence_count": 1
  }
}
```

`memory-note` generates the note ID, timestamp, destination filename, fingerprint, and envelope schema.

## Safety model

- extensions and kinds are allowlisted;
- `ad_hoc` and Chronicle are rejected;
- destinations are constructed internally under the Codex memory root;
- symlink traversal is rejected;
- writes use create-new semantics;
- exact duplicate fingerprints return `duplicate_skip`;
- obvious sensitive object keys such as `password`, `secret`, `api_key`, `access_token`, and `private_key` are rejected.

Schemas and examples are available under `schemas/` and `fixtures/`.
