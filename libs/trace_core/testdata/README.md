# Trace fixtures

These files contain synthetic source records for parser regression tests.
`nested_tool_outputs.jsonl` combines the existing Codex response-item envelope
with the `exec_command` / `write_stdin` process-result fields printed by the
`functions.exec` wrapper. It contains no private transcript or real command run.

The fixture covers several commands in one wrapper, a text block containing a
JSON array, intermediate and final output, an asynchronous wait, redirected
output readback, missing and malformed statuses, and quoted documentation.
The failed application output is passive fixture data. Its process exit is
independent of the successful wrapper exit, and its nested application error is
not promoted to another process execution.

`compressed_multiblock.jsonl.zst` is a checksummed Zstd fixture containing
150,000 copies of this 73-byte record (10,950,000 decoded bytes):

```json
{"type":"event_msg","payload":{"type":"agent_message","message":"safe"}}
```

The trailing newline is part of each record. The compressed-input test checks
every decoded byte across the decoder's sliding window, then corrupts the frame
checksum and requires failure. The smaller
`apps/seq/testdata/rollout.jsonl.zst` fixture decodes exactly to
`apps/seq/src/v1/fixtures/rollout.jsonl` and exercises mixed plain/compressed
archive discovery and aggregate decoded-byte limits.
