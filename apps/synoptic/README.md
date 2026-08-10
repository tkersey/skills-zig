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
