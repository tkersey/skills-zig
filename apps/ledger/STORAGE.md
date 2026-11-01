# Explicit managed custody roots

Ledger 1.3 adds `--store-root <absolute-directory> --store-id <id>` as an
alternative to `--repo` on `transact`, `project`, `doctor`, `migrate-segmented`,
and both `recovery` commands. The options are mutually exclusive with `--repo`.
The root contains `.ledger/`; all existing definition-relative slots, binding
history, archived definitions, transaction resources, and recovery fencing stay
inside that control directory. The passive definition ABI is unchanged.

The caller selects and initializes a root, then supplies its expected identity.
The regular file `<root>/.ledger-root.json` must contain exactly:

```json
{"schema":"ledger-storage-root/v1","store_id":"<caller-owned-stable-id>"}
```

The root and its `.ledger/` directory must already exist. Ledger rejects
symlink components, absent or malformed markers, mismatched identities, relative
roots, duplicate selectors, and missing control directories before any native
operation. Managed root failures on projections exit 3, never 0; other managed
root selection failures exit 2. They emit `ledger-storage-root-error/v1` with
`storage_mutated: false` and `authority_granted: false`.

Ledger opens the registered root and its `.ledger/` directory during admission.
The marker is read from the opened root, and all managed custody paths are
resolved relative to the opened `.ledger/` handle for the command's lifetime.
Renaming or replacing the external root or `.ledger/` pathname after admission
does not redirect that command to a replacement history. Definitions and input
files retain their own explicit path semantics.

The storage engine does not discover Git, choose a home directory, or register
a repository. Ledger 1.6 adds a separate native host interface, `ledger context`,
for explicit catalog lookup, identity validation, workspace/worktree association,
and authorized registration. The caller supplies `--catalog-root` and either
`--workspace` or a known `--store-id`. No Codex-specific location default is
compiled into Ledger. In the Codex integration, the Ledger skill body selects
the location and other owners consume its returned context.

`--repo` remains the explicit legacy/unmanaged filesystem-root interface. It
retains its existing behavior, including pure initial missing-slot semantics.
Never use it as a fallback after managed-root failure. Neither selector grants
permission to initialize, migrate, repair, or publish history.

The entry point routes host-context commands to `host_cli.zig`; `host_context.zig`,
`host_catalog.zig`, and `host_workspace.zig` implement that host layer. Engine
argument admission remains in `storage_root.zig`, with native commands in
`cli.zig`. Definitions cannot call host discovery or select catalog paths.

## Native host context

```sh
ledger context --catalog-root /selected/home --workspace /selected/workspace
ledger context --catalog-root /selected/home --store-id <existing-id>
ledger context --catalog-root /selected/home --list-stores
ledger context --help
```

Default lookup and listing are read-only, including when the catalog is absent.
`--ensure` may import a valid existing Git registration. `--initialize` explicitly
creates new custody only after checking known history; it never replaces a
missing cataloged root. `--register-root`, `--import-registration`, and
`--attach-workspace` retain existing IDs, roots, layouts, and records. Existing
`ledger-personal-catalog/v1` catalogs and Git registration files remain readable.

An owner call supplies `--definition` and its explicit `--owner-manifest`.
`--ensure-owner` prepares compatible selected history; `--read-only` refuses
necessary preparation without changing storage; `--repair-archive` selects exact
restoration. Successful preparation returns the context with the native
`preparation` result. Later catalog failure retains that result and reports
`status: blocked`; callers must not infer that a committed operation did not run.
No status worker or additional post-write health check runs.

`--migrate` separately inspects broad historical sources. Apply requires
`--apply --confirm-no-writers` and explicit owner manifests. Retired semantic
conversion remains with the owner: native `owner-import-required` identifies
the archived source inputs; the caller invokes the trusted owner constructor
and resumes with scoped `--owner-import-receipt` results. Ledger does not execute
owner code. Errors return structured JSON and exit 3, preserving known target
identity and mutation/preparation results. `authority_granted` remains false.

## Qualification

```sh
zig build build-ledger test-ledger -Doptimize=fast --summary all
zig build test-ledger-segmented -Doptimize=fast --summary all
```

Storage relocation must preserve the original history and validate destination
custody before switching its caller-owned registration. It is not a reason to
reinterpret structural receipts as authority to select among divergent logs.
