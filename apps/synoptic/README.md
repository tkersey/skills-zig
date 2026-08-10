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

File and review-thread connections are paginated independently. A file becomes
locally complete only after the mark-viewed mutation and an independent VIEWED
read-back at the same PR head.

Browser connections drain normalized model events autonomously from a single writer loop, and every
message, interrupt, close, prepare, and completion request is bound to the
originating session. Model preparation is rejected during the initial review;
same-slot cards supersede immutably; completion requires mark-viewed plus an
independent `VIEWED` read-back; close stays local.

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
to mutate a reused user checkout.

Runtime receipts contain only operational identity and launch data. They never
contain tabs, conversations, action cards, or review state. After stop or a
machine/process restart, Synoptic rebuilds the queue from GitHub and creates
fresh ephemeral Codex threads.
