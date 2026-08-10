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

The distributable feature flags remain disabled. The current E2E now drives the
real loopback server with a masked WebSocket client and a spawned fake Codex,
including primary completion, file fork/review streaming, explicit-session
messaging, and a model-originated action card. Refresh now re-queries independent
file/thread pages, advances only managed custody, injects changed-file deltas,
replaces the queue generation, and starts a background primary update.

The fixture does not yet spawn a fake `gh` to prove confirmed-comment mutation,
VIEWED read-back completion, changed-revision refresh, finish-round, and reconnect
through the same network path. Those missing effects keep the viewed-queue,
ephemeral-session, and action-card capability flags false.
