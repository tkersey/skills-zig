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
- `checked_path`: full notes directory path, or the Codex home when its invalid
  layout prevents implicit version selection;
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
An absent or null version uses Codex's v1 default, as does an absent or null
`memories` setting. Codex 0.162.1 serializes these optional TOML settings as JSON
null; see its pinned [configuration types](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/config/src/types.rs)
and [config/read implementation](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/app-server/src/config_manager_service.rs).
Missing Codex, rejected or malformed
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

`path --extension NAME` prints only `notes_dir`, preserving the 0.2.0 text
interface. `path --extension NAME --format json` returns
`schema: "memory-note-layout/v1"`, `codex_home`, `memory_version`, `memory_root`,
`extension_root`, `notes_dir`, `instructions_path`, and `resources_dir`. Adapters,
instruction deployment, and diagnostics should consume that result and pin its
home/version on subsequent commands. `--format text` also returns only `notes_dir`.
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
The staged file is flushed before rename; the publication contract does not
promise that the destination directory entry survives power loss.
An interrupted writer can leave partial control files in staging; ordinary reads
and migration inventories never treat them as admissions. Rerunning does not
require deleting those files or a recognized lock marker.

Migration bounds are 10,000 notes per directory and 1 MiB per note. Inventories
retain filenames, IDs of at most 128 bytes, and digests; raw and parsed envelopes
are released after each file. There is no aggregate history-byte limit that
shrinks when source copies are retained. Preflight rejects a planned destination
over 10,000 distinct IDs before copying; duplicates at that limit remain valid.
Dry runs create no notes or lock files. `copied` counts
published admissions; `storage_mutated` also includes first creation of the
persistent lock marker, so an empty first migration can report a control change
with zero copied notes.

Deploy regular `instructions.md` files to the selected extension roots through
the source-memory owner. Do not copy old compiled outputs or symlink memory roots.
Existing threads can retain their prior selected version; use a fresh thread to
verify a configuration cutover.

## Upgrade existing 0.2.0 use

The `memory-source-note/v1` envelope format and fingerprint computation are
unchanged. Existing regular files retain their IDs and relationships. Keep using
the old v1 location without moving anything by pinning the new executable:

```sh
memory-note path --extension learnings --memory-version v1
memory-note list --extension learnings --memory-version v1
```

An explicit version does not start Codex and works offline even when no Codex
executable is installed. Without that pin, fresh configuration can select v2;
ordinary commands then inspect v2 only. A v1 note becoming absent from that
selected view does not mean it was deleted. Use the explicit migration above
for each extension with retained admissions, and deploy its instructions to the
same selected root. Neither installation nor a routine append imports v1 notes.

Finish existing 0.2.0 writes before the first 0.3.0 write or real migration, and
upgrade every writer using that home. Old and new binaries are not safe
concurrent writers. A live old writer owns an empty sentinel; let it finish and
retry. A leftover old sentinel requires checking that no old writer is running
before explicitly retiring that specific file. Once a new persistent marker
exists, 0.2.0 writers fail `PathAlreadyExists`; old v1 readers still understand
the retained envelopes. Do not remove the marker to make mixed writers proceed.

Migration compares exact bytes. The 0.2.0 `show --format raw` output added a
newline, so a file produced by redirecting that output can differ from the
original stored file even though both parse to the same JSON. Such a mirror,
any other differing bytes under one ID, and conflicting filenames require
explicit review. Preserve both copies outside the migration destination while
identifying the authoritative stored bytes; do not recapture, rewrite an ID, or
silently normalize either admission. Copy original files when preparing a
migration. The new `show` returns the exact stored bytes.

Memory roots, extension directories, and note files must be regular paths with
no symlink ancestors. The old append contract already rejected symlink traversal;
the new read and duplicate paths enforce the same boundary. Select the actual
Codex home and prepare regular copies under its selected layout when replacing
a legacy symlink arrangement; migration does not follow symlinked source roots.

### Return to a v1 layout

Keep the new executable, stop admissions while changing the selected layout, and
copy any v2-only admissions back with the same immutable migration:

```sh
memory-note migrate --extension learnings --from-memory-version v2 --memory-version v1 --dry-run
memory-note migrate --extension learnings --from-memory-version v2 --memory-version v1
memory-note list --extension learnings --memory-version v1
```

Repeat for each used extension. Select v1 for both the writer and the Codex
reader, deploy v1 extension instructions, and verify from a fresh thread. Keep
source copies; compiled outputs are not rollback input. No lock-marker removal
is needed when using the new binary in v1 mode.

An actual executable downgrade to 0.2.0 additionally requires all new writers
to remain stopped. Complete and verify reverse migration with 0.3.0 first, then
retire only the recognized `memory-note-extension-lock/v1` marker files for the
known home and extensions before starting the old writers. Do not delete unknown
lock files or remove markers while any writer can run. The persistent marker
intentionally prevents an uncoordinated binary downgrade from bypassing the lock.

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
It also reads exact [0.2.0-produced envelopes](fixtures/legacy-v0.2.0/README.md),
checks offline v1 access and reverse migration, and retries a source exceeding
64 MiB while retaining both copies. The Python fixtures use only the standard
library on Linux and macOS. The configuration cases replay the nullable shapes
from the pinned Codex 0.162.1 source; they do not run that released executable.
These checks do not claim an installed Codex compiler run.
