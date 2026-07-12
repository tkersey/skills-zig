# ledger Synesthesia source

Internal Synesthesia-source implementation used by `ledger --source synesthesia`.
This directory is not an independently shipped CLI surface.

## Files

- `scripts/synesthesia.zig`

## Public write surface

- Primary: `ledger capture --source synesthesia --kind KIND --json FILE|-`
- Migration: `ledger migrate --source synesthesia --mode copy` copies existing
  Synesthesia memory-source notes into `.ledger/synesthesia/events.jsonl` when
  an explicit copy import is intended.
- Digest: `ledger memory-digest --source synesthesia` writes the disposable
  Synesthesia digest resource.

Current persistent-adapter path:

```bash
.ledger/synesthesia/events.jsonl
```

Capture, recall, and doctor operations use the shared backend-neutral
event-store API. JSONL remains the current compatibility adapter and explicit
note-import target; source logic does not manage file locks or parse the store.

Synesthesia capture remains gated by durable mapping or activation-boundary
authority. Ordinary metaphorical or diagnostic prose is not a ledger event.
