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
memory-note migrate --extension harness --from-memory-version v1 --dry-run
memory-note version
```

`doctor` returns JSON and exits `8` when it finds controlled memory-source
layout issues. Failed extension entries include:

- `issue`: stable machine-readable error name, such as `SymlinkComponent`;
- `checked_path`: full notes directory path that was checked;
- `offending_component`: path component that caused the issue, when it can be
  reproduced during diagnosis;
- `component_kind`: `symlink`, `not_dir`, or `unknown`.

## Selected memory layout

All commands use one selected layout. Without an explicit version, `memory-note`
starts the local `codex app-server`, initializes it, and requests `config/read`
for the current working directory with the selected `CODEX_HOME`. Codex owns
configuration layering and project trust. No thread, turn, tool, or model request
is made. `CODEX_BIN` can name an explicit Codex executable.

`memories.version = "v1"` selects `memories`; `"v2"` selects `memories_v2`.
An absent version uses Codex's v1 default. Missing Codex, rejected or malformed
configuration, an unknown version, and a timed-out response are errors; existing
directories never decide which version is active.

The fresh config read cannot reconstruct overrides or a profile selected by an
already-running thread. Pin that thread's known layout with `--memory-version
v1|v2`; use the same home and version for the entire admission or diagnostic.
The home selection is `--codex-home`, then `CODEX_HOME`, then `$HOME/.codex` and
must be absolute. Configuration I/O has a 10-second deadline, a 1 MiB aggregate
response budget, and at most 128 messages per reply.

The CLI writes immutable JSON note envelopes under the selected root:

```text
<codex-home>/<memories-or-memories_v2>/extensions/<extension>/notes/
```

`path --extension NAME --format json` (the default) returns
`schema: "memory-note-layout/v1"`, `codex_home`, `memory_version`, `memory_root`,
`extension_root`, `notes_dir`, `instructions_path`, and `resources_dir`. Adapters,
instruction deployment, and diagnostics should consume that result and pin its
home/version on subsequent commands. `--format text` returns only `notes_dir`.
The resolver and doctor do not create memory directories. The native Codex
configuration process may perform its own normal initialization.

Only the selected version is read or written during ordinary operations. A v2
compiler consumes extension instructions beside the notes and produces its
`memory_summary.md`; note existence does not prove compiler consumption or
promotion. The writer never changes compiled `memory_summary.md`, `MEMORY.md`,
or memory-root `skills/*`.

## Migrate retained admissions

Use explicit maintenance only when another layout contains existing admissions:

```sh
memory-note migrate --extension learnings --from-memory-version v1 --memory-version v2 --dry-run
memory-note migrate --extension learnings --from-memory-version v1 --memory-version v2
```

Migration copies complete stored envelopes with their original bytes, filenames,
IDs, fingerprints, capture times, and relationships. It does not read canonical
Ledger records, decide admission eligibility, recapture notes, or delete the
source. Empty sources copy no admissions; there is no bulk historical admission.

Both versions share a process-held per-extension lock under
`<codex-home>/.memory-note/locks/`. The recognized marker file stays in place;
process exit releases the operating-system lock. A concurrent writer receives
`MemoryNoteBusy`. Older sentinel-based binaries cannot enter while the marker
exists. An empty or unrecognized older lock stops with `LegacyLockNeedsReview`;
confirm that no older writer is running before explicitly retiring that legacy
sentinel. Never remove a recognized marker to bypass a current writer.

Conflict preflight precedes any note write.
An existing ID with identical envelope bytes is skipped; a differing envelope
under the same ID, a conflicting destination filename, duplicate IDs within an
inventory, or malformed stored notes stop migration. Distinct IDs remain distinct
even if their transport fingerprints match. Writes use atomic create-new
publication. An interrupted copy can leave complete copied notes; rerunning
skips those identities and continues. Source originals remain the recovery copy.
Complete envelopes are staged in the extension's `.memory-note-staging/`
directory, outside `notes/`, then published by an atomic nonreplacing rename.
An interrupted writer can leave partial control files in staging; ordinary reads
and migration inventories never treat them as admissions. Rerunning does not
require deleting those files or a recognized lock marker.

Migration bounds are 10,000 notes per directory, 1 MiB per note, and 64 MiB across
the two inventories. Dry runs create no notes or lock files. `copied` counts
published admissions; `storage_mutated` also includes first creation of the
persistent lock marker, so an empty first migration can report a control change
with zero copied notes.

Deploy regular `instructions.md` files to the selected extension roots through
the source-memory owner. Do not copy old compiled outputs or symlink memory roots.
Existing threads can retain their prior selected version; use a fresh thread to
verify a configuration cutover.

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
- completed envelopes become visible atomically;
- exact duplicate fingerprints return `duplicate_skip`;
- obvious sensitive object keys such as `password`, `secret`, `api_key`, `access_token`, and `private_key` are rejected.

Schemas and examples are available under `schemas/` and `fixtures/`.

## Development checks

```sh
zig build build-memory-note test-memory-note
bash apps/memory-note/scripts/test-cli.sh zig-out/bin/memory-note
```

The CLI regression uses temporary homes and a local configuration-protocol
fixture. It checks v2 write/list/show agreement, redirected readback, explicit v1
pinning, immutable migration and retry, conflicting histories, unknown versions,
noncreating diagnostics, a killed migration followed by exact-byte recovery,
partial staging isolation, lock contention, and duplicate-path symlink rejection.
The recovery fixture uses Python 3's standard library on Linux and macOS. These
checks do not claim an installed Codex compiler run.
