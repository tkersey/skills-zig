# Preparation working-file lifetimes

Paths below are relative to the admitted managed `.ledger` directory. Preparation and maintenance use the existing persistent CAS advisory lock for `.preparation`. Inspect opens an existing shared lock and never creates one. Native transaction recovery remains the only publication authority.

| Path | Creator | Required lifetime | Coordination | Release witness |
| --- | --- | --- | --- | --- |
| `.preparation.cas.lock.advisory` | Existing native CAS lock implementation | Persistent coordination resource | Existing native advisory lock protocol | Never reclaimed by preparation or maintenance |
| `.preparation/operation.json` | Preparation | One replaceable latest operation record | Exclusive preparation advisory lock; ready-to-installed transition participates in the native target transaction | Retained after finalization, with payload witnesses removed; never independently authorizes commit |
| `.preparation/payload-N` | Preparation, exclusive creation | Capture through native publication resolution | Exclusive preparation advisory lock; creation inode and declared size recorded before payload writes | No pending native transaction, recognized operation record, matching single-link file inode and bounded length; completed captures also require the recorded digest |
| Temporary replacement file in `.preparation` | Existing atomic publication helper | Atomic operation-record replacement | Exclusive preparation advisory lock | Existing helper's own failure cleanup only; an unrecognized leftover blocks preparation cleanup and is retained |
| `.transactions`, fencing files, target CAS lock sidecars | Existing native transaction machinery | Existing native lifetime rules | Existing native transaction protocol | No new deletion rule |
| Canonical history, bindings, definitions, revisions, caches, foreign files | Existing owners | Existing history and owner rules | Existing owner protocols | Outside preparation cleanup scope |

Payload count and total bytes use the invocation's preparation limits. The operation record is at most 1 MiB, with at most 64 KiB of flat provenance JSON. Atomic replacement needs at most one additional record-sized temporary file; native publication staging is accounted separately. Unknown artifacts, ownership mismatches, incomplete native publication, or exhausted inspection limits stop cleanup. Maintenance inspects native pending work but does not recover it. Interrupted capture can restart only after its recorded files are released under these conditions. A retry uses the same workspace and replaces the latest record.

## Commands and bounds

`ledger prepare --definition FILE --store-root ROOT --store-id ID` inspects one
static monolithic JSONL event slot. Supply repeated `--source-root PATH` for
unmanaged roots, `--source-store ID=PATH` for managed roots, or
`--source-archive ORIGINAL-TREE` for a selected original-tree location in a legacy
archive. Archive manifest validation covers the selected files and their required
metadata. Sources and unrelated payload are never destinations. `--param NAME=VALUE`
uses the existing definition parameter contract. At most 32 sources are admitted.

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
free-space inspection is not a reservation. Required transaction staging is
additional to the selected preparation payload. Maintenance's top-level file
lengths are partial metadata observations; nested/foreign sizes and physical
blocks freed remain unknown. No whole-store inventory is implied.
`staged_bytes` measures the selected payload written into the workspace and is
unknown if staging fails partway. Native transaction write traffic and actual
peak working bytes remain explicitly unknown; the peak field labeled estimated
is not a measurement. Successful finalization reports reclaimed logical payload
bytes separately from native audit/recovery metadata retained under existing rules.

## Outcomes

Preparation JSON uses `ledger-preparation-result/v1`, with owner/store identity,
phase, limits, read and staging counters, observations, known mutation state and
any transaction identity. `covered`, `empty`, `ready` and `prepared` return exit 0;
`empty` means no admitted history, not permission to initialize or replace an
established owner. `ready` is inspection evidence, not an execution token.
`reconciliation-required`, `recovery-required`, `busy`, `incomplete`, `unsupported`,
`failure` and `committed-with-later-failure` return exit 2. The latter preserves the committed installation and names the
failed later phase; retry reuses it. Operation failures preserve measured counters,
the specific `error_code`, phase and mutation observation in the preparation
result. Argument/definition/layout admission errors before operation entry retain
the existing native error envelope. No failure is an empty-history observation.

Maintenance JSON uses `ledger-maintenance-result/v1`. `healthy` returns exit 0;
`blocked`, `incomplete` and `failure` return exit 2 with the error code and measured
coverage. Mutation can be false, true or unknown. Neither schema grants semantic
or workflow authority. Native transactions remain the publication authority.

## Coordination and compatibility

Participating writers must use the existing Ledger native event, binding and
transaction coordination. Selected-source handles and metadata are revalidated
before publication. A source without the necessary existing coordination,
including an absent control directory, requires actual quiescence established by
the host and `--confirm-no-legacy-writers`; a missing PID or elapsed time is
insufficient. Preparation does not establish quiescence itself. Unsupported old
writers must be stopped or upgraded before cutover.
The mixed-version integration fixture qualifies native macOS Ledger 1.5.5 with
1.6 preparation, old-reader projection and subsequent old-writer capture. Other
old-writer combinations require the quiescent cutover route unless separately
qualified; participating 1.6 writers use the native coordination on Linux/macOS.

The `.preparation` control record adds no owner-data format. Existing readers and
healthy segmented access keep their existing routes. Unsupported preparation
layouts fail before recovery or workspace creation. Broad historical migration
remains separately selected; this command neither replaces it nor reclaims its
archives. The integration qualifies concrete Review Fold, Learnings and Negative
Ledger definitions without native owner-specific dispatch.
