## What changed

Describe the behavioral change and the owning component.

## Why

Explain the problem, the selected design, and why a narrower change is not
sufficient.

## Authority and invariants

- Authority granted or retained:
- Positive-space states:
- Negative-space states:
- Durable identity or tuple binding:
- Recovery law:

## Bounds

| Resource | Bound | Rationale |
| --- | ---: | --- |
| Input bytes | | |
| Output bytes | | |
| Records or iterations | | |
| Retries or processes | | |
| Timeout | | |

Use `not applicable` only when the resource cannot be consumed by the change.

## Error handling

List expected operating errors, programmer-error assertions, and the proof for
interruption or partial persistence.

## Performance sketch

Estimate the relevant network, disk, memory, and CPU costs. State why the
control plane and data plane remain appropriately separated.

## Validation

```text
Paste the exact commands and concise results.
```

Include positive, negative, boundary, and recovery tests.

## Compatibility and release

State affected CLIs, version changes, archive or Homebrew impact, and any schema
compatibility behavior.

## Checklist

- [ ] Every new loop, queue, read, process, and retry path is bounded.
- [ ] New or touched functions fit within 70 lines.
- [ ] New Zig lines fit within 100 columns and pass `zig fmt`.
- [ ] Programmer errors are asserted and operating errors are handled.
- [ ] Tests cover positive and negative space, including boundary mutations.
- [ ] Library options and capabilities are explicit at important call sites.
- [ ] No unresolved technical-debt markers or silent error discards remain.
- [ ] The commit message explains both what changed and why.
