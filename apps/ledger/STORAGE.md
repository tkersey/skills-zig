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

No Git discovery, home-directory default, repository registration, fallback,
automatic binding, or migration occurs in the native CLI. The caller owns those
policies. In the Codex skills integration, the Ledger skill is the single owner
of location policy and repository/worktree-family resolution. Other owners
consume that context rather than deriving their own paths.

`--repo` remains the explicit legacy/unmanaged filesystem-root interface. It
retains its existing behavior, including pure initial missing-slot semantics.
Never use it as a fallback after managed-root failure. Neither selector grants
permission to initialize, migrate, repair, or publish history.

The entry point now separates managed argument admission (`main.zig` and
`storage_root.zig`) from the unchanged native command implementation (`cli.zig`,
renamed byte-for-byte from the previous entry point). The existing CLI test suite
is retained; managed-root admission adds focused unit tests.

## Qualification

```sh
zig build build-ledger test-ledger -Doptimize=fast --summary all
zig build test-ledger-segmented -Doptimize=fast --summary all
```

Storage relocation must preserve the original history and validate destination
custody before switching its caller-owned registration. It is not a reason to
reinterpret structural receipts as authority to select among divergent logs.
