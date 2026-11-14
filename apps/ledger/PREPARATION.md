# Preparation working-file lifetimes

Explicit broad migration owns fixed private work outside canonical `.ledger` and
completed archives. The existing repository guard coordinates each lifetime.
Immutable declarations beside the pending registration bind the exact store ID,
root and permitted layout; they record no commit state. Archive admission also
accepts an existing checked catalog selection or legacy Git registration, without
requiring a pending locator. The original pending registration keeps its five-field
format. Mutating retries validate and finish locator, marker and directory syncs
before custody can be associated; inspection never performs those syncs.
Mutating directory opens replay parent-link syncs for existing and newly created
components, so a failed directory-creation sync cannot be bypassed on retry.

| Path | Creator | Required lifetime | Coordination | Release witness |
| --- | --- | --- | --- | --- |
| `<store>/.migration-copy/payload` | Explicit native migration, after `migration-copy.json` declaration | One bounded regular canonical-copy stage, at most 2 GiB | Existing repository guard | Declared layout, regular single-link file, bounded length; no native transaction depends on it. The empty directory is retired after verified completion |
| `<store>/.migration-archive` | Explicit native migration, after separate `migration-archive.json` declaration | One unpublished broad archive stage | Existing repository guard | Empty/manifest-only owned stage, or complete bounded validation against its persisted archive manifest before any deletion |
| `<store>/legacy-archive/<fingerprint>` | Existing explicit broad migration | Preserved historical evidence | Existing repository guard for publication | Never reclaimed by preparation or migration retry |
| Existing `.archiving-*` stages | Historical native/Python migration | Retained unpublished evidence | Outside new cleanup authority | Never deleted; exact historical generated names are excluded from completed-generation discovery |
| `registration.json`, `migration-archive.json` | Native host integration | Stable identity and immutable working-layout ownership | Existing repository guard and catalog coordination | Retained; no new metadata sweeper |
| `migration-copy.json` | Explicit native migration before archive capture | Copy ownership and exact selected input through interrupted capture/publication and external owner import | Existing repository guard and catalog coordination | Verified migration receipt and catalog association; clear owned scratch, durably remove its directory, then retire this declaration |

Archive capture writes and syncs the existing `ledger-legacy-archive/v1` manifest
before copying payload. Retry validates every staged path, kind, link count and
maximum length against that prior manifest before deleting anything. Each file
witness requires its size and a valid SHA-256 digest; interrupted payload may be
shorter than that witness. Implicit
parent directories are derived from its admitted paths. This permits restart when
the current source inventory changes. A malformed manifest with payload, unknown
entries, links, special files or undeclared occupied paths remain untouched and
block that operation. A partial manifest without payload may restart. Working
payload is bounded by the existing 2 GiB inventory limit and 100,000 inventory
entries; the prior manifest read has a separate 2 GiB ceiling. Directory inspection
is bounded by the finite allowed-path set, including implicit parents.

Canonical-copy publication and completed archive publication use nonreplacing
rename. Existing destinations are verified, and retries finish directory syncs
before returning success. Source files, completed archives and ambiguous canonical
files are never overwritten or removed. Identical failed captures retain one bulk
stage, independently of retry count. The existing archive schema, fingerprint and
receipt contracts remain unchanged. Cold adoption retains its outer directory
publication and reuses native `History.covers` per static slot under its existing
aggregate 2 GiB/100,000-entry inventory bounds; routine preparation keeps the
defaults and ceilings below.

Explicit broad migration selects one source covering every selected slot's native
binding history and required definitions/revisions. Equal event bytes alone do
not establish coverage. Selection retains the observed before-state of supported
unbound or stale histories; it cannot use an unbound history to hide conflicting
bindings. Only the owner's existing `bind-existing` or `rebind-existing` operation
can repair that state. A read-only preview reuses native maintenance preparation
to derive its exact binding result, without another store or persistent format.
Registered coverage, partial-copy retry, final verification and receipt reuse
require the same selected native history or that exact repair result, followed by
valid native continuation. This preserves retired imports and registered recovery
after receipt deletion. Incomplete copying resumes only when existing selected
members match the admitted original exactly; unrelated bindings are not a repair
fallback. Source comparison retains one slot's bounded source observations at a
time under the broad 2 GiB/100,000-entry limits, releasing them before the next slot.
The copy declaration binds selected paths, lengths and digests, excluding unrelated
inventory and source location. A matching pending identity retains this exact-copy
permission across explicit registration, without treating registration as completed
migration. A changed selected input cannot reuse it. Successful completion consumes
the permission; deleting a later receipt or canonical history cannot revive it.
Receipt retries finish interrupted declaration retirement without another copy.

External retired-import receipts retain scalar `revision` for one-slot owners.
For multiple static event slots, `revisions` maps every declared relative slot path
to its current native revision (or null for a missing slot), with no extra keys.
Identity, definition closure, archived-source hashes and independent full-record
parity remain required for both forms.

Native host context distinguishes verified Git identity from a plain workspace;
failed Git discovery with Git metadata present cannot allocate replacement custody.
Existing catalog lookup and healthy present owner ensure do not require sibling
availability. Explicit `context --reconcile-owner` coverage does:
healthy selected history is compared against bounded live Git-family candidates,
using native bindings and one aggregate read allowance, without inspecting archives
or inferring conversion from retained retired files. A longer live history requires
reconciliation and cannot advance a healthy target through preparation.
Actual live history requires qualified native guards or actual writer quiescence.
For an absent monolithic owner in an accessible source, owner preparation creates
the native advisory resources through the lock API and acquires shared event and
binding custody before accepting its absence. Shared custody is retained through
final revalidation and publication. Source coordination mutation is reported
separately and contributes to the host's aggregate mutation result; source payloads
are never modified. Residual binding, pending publication, missing roots, and
changed identities cannot use the empty-source route. First preparation retains
one pending target identity across interruption, including after source coordination.
Ordinary healthy owner access reports source coverage as not checked, independently
of selector syntax. Strict reconciliation and absent-owner preparation retain the
full source requirements. Successful preparation or reconciliation with a workspace
reports checked coverage of that observed family. Direct-ID archive restoration
reports not checked because it does not inspect a live source family. None of these
observations is a permanent fence against later legacy writes.
Manifest-selected archive evidence cannot become empty history when its payload
is missing. Explicit archive repair requires the surviving original binding and
selected archive evidence; that binding remains required through native publication.

Cold adoption uses the same fresh-identity admission as initialization: selected
pending registration or unregistered custody blocks another allocation even when
an unrelated catalog exists. Publication failures retain the original root and ID;
explicit `context --register-root` can associate a verified published orphan. No
automatic orphan recovery or additional publication journal is introduced.

Ownership assumes participating callers obey the repository guard and private
scratch is not modified by an uncoordinated writer. Deterministic write, rename
and sync fault tests establish retry behavior; they do not simulate power loss.
Existing catalog metadata temporary files retain their existing cleanup rules.

Paths below are relative to the admitted managed `.ledger` directory. Preparation and maintenance use the existing persistent CAS advisory lock for `.preparation`. Inspect opens an existing shared lock and never creates one. Native transaction recovery remains the only publication authority.

| Path | Creator | Required lifetime | Coordination | Release witness |
| --- | --- | --- | --- | --- |
| `.preparation.cas.lock.advisory` | Existing native CAS lock implementation | Persistent coordination resource | Existing native advisory lock protocol | Never reclaimed by preparation or maintenance |
| `.preparation.json` | Native publication transaction | One bounded replaceable receipt with selected witnesses and flat provenance | Same transaction and expected-before checks as selected history | Retained after finalization; never independently advances publication |
| `.transactions/<transaction>/transaction.json`, `commit.json`, and listed native stage files | Existing native transaction machinery | Native preparing record precedes every bulk stage; stages become canonical files by native rename | Existing native transaction and recovery locks | Existing native recovery and compaction rules; no new reclamation policy |
| Fencing files and CAS advisory sidecars | Existing native coordination | Persistent coordination resources | Existing native protocols | Never reclaimed by preparation or maintenance |
| Canonical history, bindings, definitions, revisions, caches, foreign files | Existing owners | Existing history and owner rules | Existing owner protocols | Outside preparation cleanup scope |

Selected bytes are captured and validated within the invocation's memory and I/O
bounds, then staged once by the native transaction. There is no separate payload
copy or operation-record update protocol. The receipt is at most 1 MiB with at
most 64 KiB of flat provenance. Inspecting a retained receipt validates its metadata
within the read allowance; its historical payload lengths do not consume a later
owner's capture allowance. New capture still enforces its selected byte/file limits.
One unresolved transaction blocks another capture;
valid preparing journals allow native rollback of incomplete staging. A malformed
initial native journal remains an explicit unknown: retries retain that metadata
and stop before another transaction or bulk stage. Universal automatic recovery
from damaged native metadata is not claimed.

Maintenance never advances unresolved transactions or compacts their audit journals.
Successful native publication renames every bulk stage into canonical history;
there is no independent preparation payload to reclaim. Required native metadata
retains its existing lifetime and is observed separately. Normal preparation
uses existing native recovery and compaction when unresolved work is present.
An old `.preparation` directory is retained as unknown work rather than bypassed
or removed. No new native artifact deletion policy is introduced.

## Commands and bounds

`ledger prepare --definition FILE --store-root ROOT --store-id ID` inspects one
static monolithic JSONL event slot. Supply repeated `--source-root PATH` for
unmanaged roots, `--source-store ID=PATH` for managed roots, or
`--source-archive ORIGINAL-TREE` for a selected original-tree location in a legacy
archive. Archive manifest validation covers the selected files and their required
metadata. Sources and unrelated payload are never destinations. `--param NAME=VALUE`
uses the existing definition parameter contract. At most 32 sources are admitted.

Published archive generations have a manifest at
`legacy-archive/<generation>/manifest.json`. A manifest directly at
`legacy-archive/manifest.json` identifies an earlier, unsupported inventory layout
and returns `UnsupportedLegacyArchiveLayout`. Its shared schema name does not
prove compatibility. The archive and any neighboring generations remain intact;
general historical import requires a verified adapter for that manifest shape.

Exact restoration of an already bound, missing canonical slot has a separate
proof available through
`prepare --restore-bound-history --source-root ORIGINAL-TREE`. Every invocation
requires an existing binding for a missing target slot; an empty unbound target
returns `PreparationRequiresBoundHistory`. The candidate must contain a complete
native history whose binding bytes equal the surviving target binding, whose event
digest equals that binding's last revision, and whose required definition and
revision archives pass native replay. This can use an explicitly selected retained
tree even when its enclosing archive inventory is unsupported. Inspect preparation
without `--apply`, then apply a `ready` exact candidate while retaining
`--restore-bound-history` and satisfying the existing writer-coordination
requirement. Missing candidate bindings, incomplete native metadata, mismatched
history and symlinked payloads remain blockers. The original target binding must
remain present and unchanged through publication. This recovers that selected
native history without asserting general archive provenance or workspace-family
migration completeness. Sources remain unchanged.

`ledger maintain --store-root ROOT --store-id ID` inspects preparation work and a
bounded top-level metadata view. It does not recover native transactions or prepare
an owner. Both commands inspect by default; `--apply` selects authorized mutation.
Inspection does not create locks, workspaces, catalog associations or health files.
`--format json` is the default; `text` provides a short human-readable result.

| Option | Default | Accepted range |
| --- | --- | --- |
| `--max-bytes` | 67,108,864 (64 MiB) | 1–1,073,741,824 |
| `--max-files` | 512 | 2–1023 |
| `--max-read-bytes` | 1,073,741,824 (1 GiB) | 1–17,179,869,184 |

Read accounting covers operation I/O, including source admission, relevant
markers/manifests, repeated native validation, publication, recovery, installed
verification and cleanup. The same allowance follows the filesystem authority;
rejected streams retain their charges. The initial CLI definition load (at most
128 files and 4 MiB total) and initial target marker admission (4 KiB) are separately
bounded invocation inputs. Their actual transferred-byte count is unavailable;
`bytes_read` does not claim to measure total process I/O. Final target revalidation
is inside the operation counter. The derived stream-count ceiling is 16 times
`max_files` for preparation and four times `max_files` for maintenance.

Logical staged bytes,
estimated peak additional bytes and available space are separate observations;
free-space inspection is not a reservation. Native transaction staging is the sole durable selected-payload workspace. Maintenance's top-level file
lengths are partial metadata observations; nested/foreign sizes and physical
blocks freed remain unknown. No whole-store inventory is implied.
`staged_bytes` measures selected payload staged by the successful native transaction,
excluding matching immutable files reused in place; it is unknown after interrupted staging. Native transaction write traffic and actual
peak working bytes remain explicitly unknown; the peak field labeled estimated
is not a measurement. Successful publication transfers staged bytes rather than deleting a duplicate;
`reclaimed_bytes` is zero for that transfer. If existing native recovery mutates
working storage, its reclaimed logical byte count remains unknown unless measured.
Native audit metadata and the bounded receipt are retained separately.

## Outcomes

Preparation JSON uses `ledger-preparation-result/v1`, with owner/store identity,
phase, limits, read and staging counters, observations, known mutation state and
any transaction identity. `covered`, `empty`, `ready` and `prepared` return exit 0;
`empty` means no admitted history, not permission to initialize or replace an
established owner. `ready` is inspection evidence, not an execution token.
`reconciliation-required`, `recovery-required`, `busy`, `incomplete`, `unsupported`,
`failure`, `unknown` and `committed-with-later-failure` return exit 2. The latter preserves the committed installation and names the
failed later phase; retry reuses it. Operation failures preserve measured counters,
the specific `error_code`, phase and mutation observation in the preparation
result. Argument/definition/layout admission errors before operation entry retain
the existing native error envelope. No failure is an empty-history observation.

`prior_preparation` retains the store-wide work observation when a later step fails.
Its `installed` flag records an earlier native installation, not installation of
the currently selected owner. `observed_by` identifies inspection or reconciliation;
an inspection observation retained across a failed recovery is historical evidence,
not certification of that recovery. `activity` identifies the observation,
and `complete: false` marks partial observations. Unresolved or malformed native work reports `recovery-required` and is retained;
a receipt never overrides the native publication outcome.
`committed-with-later-failure` identifies this invocation's committed transaction.
Native transaction observations distinguish no retained journal, pending publication,
uncertain initial-journal cleanup, and the native committed record/marker witness.
A known transaction ID may therefore accompany pending or unknown outcomes; its
presence alone does not mean committed. Failure after marker publication but before
the final directory sync is reported as committed with a later failure. This does
not certify that sync or add a durable-retry guarantee to the existing native protocol.
Budget exhaustion before unresolved work is established reports `incomplete`;
known pending publication retains `recovery-required` even if further reads cannot
finish or a subsequent lock acquisition is busy. Prior inspection stops on a positive
native pending-work witness. A phase label alone does not establish pending work.
Known observations survive later failures; native recovery reports
`reclaimed_bytes: null` when its deletion count is unavailable. New capture uses its own observations and cannot inherit an older
installation's success.

Maintenance JSON uses `ledger-maintenance-result/v1`. `healthy` returns exit 0;
`blocked`, `incomplete` and `failure` return exit 2 with the error code and measured
coverage. Mutation can be false, true or unknown. Neither schema grants semantic
or workflow authority. Native transactions remain the publication authority.

## Coordination and compatibility

Participating writers must use the existing Ledger native event, binding and
transaction coordination. Selected-source handles and metadata are revalidated
before publication. Directory identity compares device and inode through opened
handles; ordinary directory timestamp changes do not replace that identity.
A source without the necessary existing coordination,
including an absent control directory, requires actual quiescence established by
the host and `--confirm-no-legacy-writers`; a missing PID or elapsed time is
insufficient. Preparation does not establish quiescence itself. Unsupported old
writers must be stopped or upgraded before cutover.
The mixed-version integration fixture qualifies native macOS Ledger 1.5.5 with
1.6 preparation, old-reader projection and subsequent old-writer capture. Other
old-writer combinations require the quiescent cutover route unless separately
qualified; participating 1.6 writers use the native coordination on Linux/macOS.

The `.preparation.json` receipt adds no owner-data format. Existing readers and
healthy segmented access keep their existing routes. Unsupported preparation
layouts fail before recovery or workspace creation. Broad historical migration
remains separately selected; this command neither replaces it nor reclaims its
archives. The integration qualifies concrete Review Fold, Learnings and Negative
Ledger definitions without native owner-specific dispatch.

Coverage follows validated native binding history. For nonprotocol histories with
`compare_replace`, an older payload is compared with its corresponding archived
epoch in the newer candidate, rather than only the newer current payload. Required
definitions and revisions must still match. A target behind a later replacement
reports reconciliation-required; preparation does not advance it.
