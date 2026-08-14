# Synoptic

Synoptic is the native, macOS-only process behind the `$synoptic` per-file PR
review workbench. `launch` starts a detached `serve` child, waits until its
loopback HTTP/WebSocket listener is ready, prints the verified receipt, opens
the browser by default, and returns. `status` and `stop` act only on the exact
live launch identity recorded under `$TMPDIR/synoptic`; `app.stop` provides the
same quit boundary from the browser.

```sh
synoptic version
synoptic capabilities --format json
synoptic launch --cwd "$PWD" --skill-root "$HOME/.codex/skills/synoptic" --json
synoptic status --json
synoptic stop --json
```

The current native slice serves the browser from the validated skill root. GitHub calls use fixed
`gh api graphql --hostname HOST --input -` argv and JSON stdin; the browser has
no shell or generic GitHub endpoint.

Before binding the UI, Synoptic generates the installed Codex app-server schema
and verifies the thread, turn, skill-input, notification, injection, and dynamic-tool
surfaces it uses. The hidden primary and every file fork receive the explicit
`synoptic` skill item and skill-owned role instructions. PR metadata, canonical
diffs, and unresolved-thread evidence are always computed by the server; a
browser `file.open` command supplies only the selected path.

File and review-thread connections are paginated independently. A file becomes
locally complete only after the mark-viewed mutation and an independent VIEWED
read-back at the same PR head.

Browser connections drain normalized model events autonomously from a single writer loop, and every
message, interrupt, close, prepare, and completion request is bound to the
originating session. Model preparation is rejected during the initial review;
same-slot cards supersede immutably; completion requires mark-viewed plus an
independent `VIEWED` read-back; close stays local.

Command-execution approvals are bound to either the exact visible file session
or the server-owned hidden primary thread. The browser receives an opaque
pending approval and only the app-server-advertised decisions; its resolution
wakes that exact server request once without exposing the primary transcript.
Permission-escalation and file-change approvals fail closed. Unknown, duplicate,
cross-owner, expired, deprecated, ambiguous, and otherwise unowned requests also
fail closed. Pending approvals decline on timeout, disconnect, synchronization,
session close, and shutdown.

The action broker uses one immutable `synoptic-github-action/v1` carrier for
typed review actions and bounded transparent GraphQL. Confirmation accepts only
the card ID, revalidates the current PR target and viewer authority, and never
retries an ambiguous mutation. Transparent documents are limited to one named,
unaliased mutation root whose variables bind the exact current pull request;
the immutable preview and confirmation remain the effect authority boundary.

The native capability flags are enabled. The real loopback fixture uses masked
WebSocket clients plus spawned fake Codex and fake `gh` processes to prove the
primary gate, file forks and streamed reviews, model-originated immutable cards,
exact fixed-argv inline-comment confirmation, explicit completion with independent
`VIEWED` read-back, and close-without-viewed-mutation behavior.

The same fixture also proves managed-custody refresh reconciliation, stale-origin
delta injection, a fresh official revision session, Finish-round increment, and
reconnect snapshots containing the queue, tabs, cards, and round. Production
refresh continues to re-query file and thread pagination independently and refuses
to mutate while review commands are active. Safe boundaries interrupt active
turns and wait boundedly for command quiescence. Managed custody restores tracked
files to the selected head and removes only artifacts created after its baseline;
reused custody never cleans user content and advances only through a clean
fast-forward of the original PR branch.

The native process validates `assets/exclusions.json` from the skill package and
loads the optional `${XDG_CONFIG_HOME:-$HOME/.config}/synoptic/config.toml`.
The supported settings are limited to file-session immediate/idle start,
browser opening, current-checkout preference, and exclusion enable/add/remove
globs. Strong excluded-file matches are marked viewed immediately and disappear
only after a same-head `VIEWED` read-back; failures remain queued with their
stable exclusion reason and synchronization error. Idle sessions retain the
same server-owned diff, thread evidence, skill item, and role instructions for
their first human-started turn.

Runtime receipts contain only operational identity and launch data. They never
contain tabs, conversations, action cards, or review state. After stop or a
machine/process restart, Synoptic rebuilds the queue from GitHub and creates
fresh ephemeral Codex threads.

## Release contract

Synoptic is released only for macOS. `synoptic-v<version>` must equal
`apps/synoptic/VERSION`, and the release contains exactly these archives:

- `synoptic-v<version>-darwin-arm64.tar.gz`
- `synoptic-v<version>-darwin-x86_64.tar.gz`

Each archive contains one executable at its root named `synoptic`. The native
runner and packaged binary architecture are verified before publication, as are
the exact `synoptic version` value (`synoptic <version>`) and the `synoptic-skill-abi/v1`,
`synoptic-ui/v1`, and four v1 capability flags reported by
`synoptic capabilities --format json`. No Linux or Windows Synoptic artifact is
published.

`libs/cas_runtime/**` is shipped by both CAS and Synoptic. A material change to
that shared runtime therefore requires coupled `apps/cas/VERSION` and
`apps/synoptic/VERSION` bumps even when only one product-facing caller changes.
