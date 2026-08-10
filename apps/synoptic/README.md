# Synoptic

Synoptic is the native, macOS-only process behind the `$synoptic` per-file PR
review workbench. `launch` is owner-lived: the terminal process owns the Codex
app-server and loopback HTTP/WebSocket listener until it is interrupted.

```sh
synoptic version
synoptic capabilities --format json
synoptic launch --cwd "$PWD" --skill-root "$HOME/.codex/skills/synoptic" --json
```

The current native slice serves the browser from the validated skill root. GitHub calls use fixed
`gh api graphql --hostname HOST --input -` argv and JSON stdin; the browser has
no shell or generic GitHub endpoint.

File and review-thread connections are paginated independently. A file becomes
locally complete only after the mark-viewed mutation and an independent VIEWED
read-back at the same PR head.

The current capability receipt remains `preview`. Browser connections now drain
normalized model events autonomously from a single writer loop, and every
message, interrupt, close, prepare, and completion request is bound to the
originating session. Model preparation is rejected during the initial review;
same-slot cards supersede immutably; completion requires mark-viewed plus an
independent `VIEWED` read-back; close stays local.

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
